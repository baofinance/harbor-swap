// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";

/// @title FxSaveWstEthSwapper_v1
/// @notice Composite `ISwapExecutor` for the peg-critical fxSAVE ↔ wstETH routes on Ethereum
///         mainnet.
/// @dev Forward (Harbor `distribute()` Phase 3): fxSAVE → scrvUSD shares → redeem → wstETH.
///      Reverse (Curve UI path): wstETH → crvUSD → scrvUSD deposit → fxSAVE.
///      Route constants live in `ConfigFxSaveWstEthRoute_ETH_mainnet`. Only `(FXSAVE, WSTETH)`
///      and `(WSTETH, FXSAVE)` are supported. Slippage is enforced on final output; intermediate
///      legs use `min_dy = 0` on Curve calls (consumer passes oracle-bounded `minAmountOut`).
///      Curve pools are invoked via low-level `exchange` calls with balance-delta accounting,
///      matching `CurveSwapper_v1` behaviour for void-return and uint256-return pools.
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence
contract FxSaveWstEthSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error PoolCallFailed(bytes revertData);
    error VaultRedeemFailed();
    error VaultDepositFailed();

    /// @notice Emitted after a successful fxSAVE ↔ wstETH composite swap.
    /// @param intermediateAmount crvUSD after vault redeem (forward) or after Tricrypto (reverse).
    event FxSaveWstEthSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 intermediateAmount,
        uint256 amountOut
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    /// @inheritdoc ISwapExecutor
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        if (fromToken == _fxSave() && toToken == _wstEth()) {
            return _swapFxSaveToWstEth(msg.sender, amountIn, minAmountOut);
        }
        if (fromToken == _wstEth() && toToken == _fxSave()) {
            return _swapWstEthToFxSave(msg.sender, amountIn, minAmountOut);
        }
        revert UnsupportedPair(fromToken, toToken);
    }

    function _swapFxSaveToWstEth(
        address recipient,
        uint256 amountIn,
        uint256 minAmountOut
    ) private returns (uint256 amountOut) {
        IERC20(_fxSave()).safeTransferFrom(recipient, address(this), amountIn);

        uint256 wstEthBefore = IERC20(_wstEth()).balanceOf(address(this));
        uint256 scrvUsdBefore = IERC20(_scrvUsdVault()).balanceOf(address(this));

        _curveExchange(_poolFxSaveScrvUsd(), _pool2IFxSave(), _pool2JScrvUsd(), _fxSave(), amountIn, 0);

        // Delta, not full balance: consume only the shares this leg produced so any
        // pre-existing (donated) scrvUSD balance is left untouched rather than swept out.
        uint256 vaultShares = IERC20(_scrvUsdVault()).balanceOf(address(this)) - scrvUsdBefore;

        IERC20(_scrvUsdVault()).forceApprove(_scrvUsdVault(), vaultShares);
        uint256 crvUsdOut = IERC4626(_scrvUsdVault()).redeem(vaultShares, address(this), address(this));
        IERC20(_scrvUsdVault()).forceApprove(_scrvUsdVault(), 0);
        // slither-disable-next-line incorrect-equality
        if (crvUsdOut == 0) {
            revert VaultRedeemFailed();
        }

        _curveExchange(_poolTricryptoLlama(), _pool1ICrvUsd(), _pool1JWstEth(), _crvUsd(), crvUsdOut, minAmountOut);

        amountOut = IERC20(_wstEth()).balanceOf(address(this)) - wstEthBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountOut, minAmountOut);
        }

        emit FxSaveWstEthSwap(recipient, _fxSave(), _wstEth(), amountIn, crvUsdOut, amountOut);

        IERC20(_wstEth()).safeTransfer(recipient, amountOut);
    }

    function _swapWstEthToFxSave(
        address recipient,
        uint256 amountIn,
        uint256 minAmountOut
    ) private returns (uint256 amountOut) {
        IERC20(_wstEth()).safeTransferFrom(recipient, address(this), amountIn);

        uint256 fxSaveBefore = IERC20(_fxSave()).balanceOf(address(this));
        uint256 crvUsdBefore = IERC20(_crvUsd()).balanceOf(address(this));

        _curveExchange(_poolTricryptoLlama(), _pool1JWstEth(), _pool1ICrvUsd(), _wstEth(), amountIn, 0);

        // Delta, not full balance: deposit only the crvUSD this leg produced so any
        // pre-existing (donated) crvUSD balance is left untouched rather than swept out.
        uint256 crvUsdBal = IERC20(_crvUsd()).balanceOf(address(this)) - crvUsdBefore;
        // slither-disable-next-line incorrect-equality
        if (crvUsdBal == 0) {
            revert VaultDepositFailed();
        }

        IERC20(_crvUsd()).forceApprove(_scrvUsdVault(), crvUsdBal);
        uint256 vaultShares = IERC4626(_scrvUsdVault()).deposit(crvUsdBal, address(this));
        IERC20(_crvUsd()).forceApprove(_scrvUsdVault(), 0);
        // slither-disable-next-line incorrect-equality
        if (vaultShares == 0) {
            revert VaultDepositFailed();
        }

        _curveExchange(
            _poolFxSaveScrvUsd(),
            _pool2JScrvUsd(),
            _pool2IFxSave(),
            _scrvUsdVault(),
            vaultShares,
            minAmountOut
        );

        amountOut = IERC20(_fxSave()).balanceOf(address(this)) - fxSaveBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountOut, minAmountOut);
        }

        emit FxSaveWstEthSwap(recipient, _wstEth(), _fxSave(), amountIn, crvUsdBal, amountOut);

        IERC20(_fxSave()).safeTransfer(recipient, amountOut);
    }

    function _curveExchange(
        address pool,
        int128 i,
        int128 j,
        address tokenIn,
        uint256 amountIn,
        uint256 minDy
    ) private {
        IERC20(tokenIn).forceApprove(pool, amountIn);
        bytes memory callData = abi.encodeWithSignature(
            "exchange(int128,int128,uint256,uint256)",
            i,
            j,
            amountIn,
            minDy
        );
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory revertData) = pool.call(callData); // solhint-disable-line avoid-low-level-calls
        IERC20(tokenIn).forceApprove(pool, 0);
        if (!ok) {
            revert PoolCallFailed(revertData);
        }
    }

    function _fxSave() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.FXSAVE;
    }

    function _wstEth() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.WSTETH;
    }

    function _crvUsd() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.CRVUSD;
    }

    function _scrvUsdVault() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.SCRVUSD_VAULT;
    }

    function _poolFxSaveScrvUsd() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD;
    }

    function _poolTricryptoLlama() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_TRICRYPTO_LLAMA;
    }

    function _pool2IFxSave() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL2_I_FXSAVE;
    }

    function _pool2JScrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL2_J_SCRVUSD;
    }

    function _pool1ICrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL1_I_CRVUSD;
    }

    function _pool1JWstEth() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL1_J_WSTETH;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
