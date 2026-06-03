// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";

/// @title FxSaveWstEthSwapper_v1
/// @notice Composite `ISwapExecutor` for the peg-critical fxSAVE → wstETH route on Ethereum
///         mainnet. Executes three on-chain steps atomically:
///           1. Curve fxSAVE/scrvUSD pool: fxSAVE → scrvUSD vault shares
///           2. scrvUSD vault redeem: shares → crvUSD
///           3. Curve TricryptoLLAMA pool: crvUSD → wstETH
/// @dev Route constants live in `ConfigFxSaveWstEthRoute_ETH_mainnet`. Only `(FXSAVE, WSTETH)`
///      is supported. Slippage is enforced on final wstETH output; intermediate legs use
///      `min_dy = 0` on Curve calls (HY passes an oracle-bounded `minAmountOut` for wstETH).
///      Curve pools are invoked via low-level `exchange` calls with balance-delta accounting,
///      matching `CurveSwapper_v1` behaviour for void-return and uint256-return pools.
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence
contract FxSaveWstEthSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error PoolCallFailed(bytes revertData);
    error VaultRedeemFailed();

    /// @notice Emitted after a successful fxSAVE → wstETH composite swap.
    event FxSaveWstEthSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 crvUsdOut,
        uint256 amountOut
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    /// @inheritdoc ISwapExecutor
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        if (fromToken != _fxSave() || toToken != _wstEth()) {
            revert UnsupportedPair(fromToken, toToken);
        }

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 wstEthBefore = IERC20(_wstEth()).balanceOf(address(this));

        // Step 1: fxSAVE → scrvUSD vault shares on fxSAVE/scrvUSD pool.    
        _curveExchange(_poolFxSaveScrvUsd(), _pool2IFxSave(), _pool2JScrvUsd(), _fxSave(), amountIn, 0);

        uint256 vaultShares = IERC20(_scrvUsdVault()).balanceOf(address(this));

        // Step 2: scrvUSD vault shares → crvUSD.
        IERC20(_scrvUsdVault()).forceApprove(_scrvUsdVault(), vaultShares);
        uint256 crvUsdOut = IERC4626(_scrvUsdVault()).redeem(vaultShares, address(this), address(this));
        IERC20(_scrvUsdVault()).forceApprove(_scrvUsdVault(), 0);
        if (crvUsdOut == 0) {
            revert VaultRedeemFailed();
        }

        // Step 3: crvUSD → wstETH on TricryptoLLAMA.
        _curveExchange(_poolTricryptoLlama(), _pool1ICrvUsd(), _pool1JWstEth(), _crvUsd(), crvUsdOut, minAmountOut);

        amountOut = IERC20(_wstEth()).balanceOf(address(this)) - wstEthBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountOut, minAmountOut);
        }

        emit FxSaveWstEthSwap(msg.sender, fromToken, toToken, amountIn, crvUsdOut, amountOut);

        IERC20(_wstEth()).safeTransfer(msg.sender, amountOut);
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
        bytes memory callData =
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", i, j, amountIn, minDy);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory revertData) = pool.call(callData);
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
