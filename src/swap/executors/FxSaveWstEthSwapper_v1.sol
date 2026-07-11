// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {Token} from "@bao/Token.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";

/// @title FxSaveWstEthSwapper_v1
/// @notice Composite `ISwapExecutor` for the peg-critical fxSAVE ↔ wstETH routes on Ethereum
///         mainnet.
/// @dev Forward (Harbor `distribute()` Phase 3): fxSAVE → scrvUSD shares → redeem → wstETH.
///      Reverse (Curve UI path): wstETH → crvUSD → scrvUSD deposit → fxSAVE.
///      Route constants live in `ConfigFxSaveWstEthRoute_ETH_mainnet`. Only `(FXSAVE, WSTETH)`
///      and `(WSTETH, FXSAVE)` are supported. The SwapExecutorBase envelope enforces slippage
///      on the final output; intermediate legs use `min_dy = 0` on Curve calls (consumer
///      passes oracle-bounded `minAmountOut`) and measure their outputs as balance deltas so
///      donated balances are never swept through the route.
///      Curve pools are invoked through `CurveExchangeLib` (low-level `exchange` encoded per
///      pool family). The two pools on this route are in DIFFERENT Curve families:
///      fxSAVE/scrvUSD is StableSwap-NG (int128 indices), TricryptoLLAMA is a crypto pool
///      (uint256 indices).
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence
contract FxSaveWstEthSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error VaultRedeemFailed();
    error VaultDepositFailed();

    /// @notice Emitted mid-route on every composite swap.
    /// @param intermediateAmount crvUSD after vault redeem (forward) or after Tricrypto
    ///        (reverse). The final output is the swap's return value (and the envelope's
    ///        Transfer to the caller), so it is not repeated here.
    event FxSaveWstEthSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 intermediateAmount
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
        (amountOut, ) = _swapEnvelope(fromToken, toToken, amountIn, minAmountOut, "");
    }

    /// @dev Dispatch to the composite legs. The envelope has already pulled `amountIn` of
    ///      `fromToken` and will measure/deliver the `toToken` output.
    function _execute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory
    ) internal override {
        if (fromToken == _fxSave() && toToken == _wstEth()) {
            _executeFxSaveToWstEth(amountIn, minAmountOut);
        } else if (fromToken == _wstEth() && toToken == _fxSave()) {
            _executeWstEthToFxSave(amountIn, minAmountOut);
        } else {
            revert UnsupportedPair(fromToken, toToken);
        }
    }

    function _executeFxSaveToWstEth(uint256 amountIn, uint256 minAmountOut) private {
        uint256 scrvUsdBefore = IERC20(_scrvUsdVault()).balanceOf(address(this));

        _curveExchange(
            _poolFxSaveScrvUsd(),
            _poolFxSaveScrvUsdKind(),
            _pool2IFxSave(),
            _pool2JScrvUsd(),
            _fxSave(),
            amountIn,
            0
        );

        // Delta, not full balance: consume only the shares this leg produced so any
        // pre-existing (donated) scrvUSD balance is left untouched rather than swept out.
        uint256 vaultShares = IERC20(_scrvUsdVault()).balanceOf(address(this)) - scrvUsdBefore;
        // slither-disable-next-line incorrect-equality
        if (vaultShares == 0) {
            revert Token.ZeroInputBalance(_scrvUsdVault());
        }

        // No share approval is needed: this contract calls `redeem` on the vault itself and
        // is also the `owner` argument, and ERC-4626 only spends an allowance when the
        // caller and the owner differ.
        uint256 crvUsdOut = IERC4626(_scrvUsdVault()).redeem(vaultShares, address(this), address(this));
        // slither-disable-next-line incorrect-equality
        if (crvUsdOut == 0) {
            revert VaultRedeemFailed();
        }

        emit FxSaveWstEthSwap(msg.sender, _fxSave(), _wstEth(), amountIn, crvUsdOut);

        _curveExchange(
            _poolTricryptoLlama(),
            _poolTricryptoLlamaKind(),
            _pool1ICrvUsd(),
            _pool1JWstEth(),
            _crvUsd(),
            crvUsdOut,
            minAmountOut
        );
    }

    function _executeWstEthToFxSave(uint256 amountIn, uint256 minAmountOut) private {
        uint256 crvUsdBefore = IERC20(_crvUsd()).balanceOf(address(this));

        _curveExchange(
            _poolTricryptoLlama(),
            _poolTricryptoLlamaKind(),
            _pool1JWstEth(),
            _pool1ICrvUsd(),
            _wstEth(),
            amountIn,
            0
        );

        // Delta, not full balance: deposit only the crvUSD this leg produced so any
        // pre-existing (donated) crvUSD balance is left untouched rather than swept out.
        uint256 crvUsdBal = IERC20(_crvUsd()).balanceOf(address(this)) - crvUsdBefore;
        // slither-disable-next-line incorrect-equality
        if (crvUsdBal == 0) {
            revert Token.ZeroInputBalance(_crvUsd());
        }

        emit FxSaveWstEthSwap(msg.sender, _wstEth(), _fxSave(), amountIn, crvUsdBal);

        IERC20(_crvUsd()).forceApprove(_scrvUsdVault(), crvUsdBal);
        uint256 vaultShares = IERC4626(_scrvUsdVault()).deposit(crvUsdBal, address(this));
        IERC20(_crvUsd()).forceApprove(_scrvUsdVault(), 0);
        // slither-disable-next-line incorrect-equality
        if (vaultShares == 0) {
            revert VaultDepositFailed();
        }

        _curveExchange(
            _poolFxSaveScrvUsd(),
            _poolFxSaveScrvUsdKind(),
            _pool2JScrvUsd(),
            _pool2IFxSave(),
            _scrvUsdVault(),
            vaultShares,
            minAmountOut
        );
    }

    function _curveExchange(
        address pool,
        CurveExchangeLib.CurvePoolKind kind,
        int128 i,
        int128 j,
        address tokenIn,
        uint256 amountIn,
        uint256 minDy
    ) private {
        IERC20(tokenIn).forceApprove(pool, amountIn);
        CurveExchangeLib.exchange(pool, kind, false, i, j, amountIn, minDy);
        IERC20(tokenIn).forceApprove(pool, 0);
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

    function _poolFxSaveScrvUsdKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD_KIND;
    }

    function _poolTricryptoLlama() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_TRICRYPTO_LLAMA;
    }

    function _poolTricryptoLlamaKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_TRICRYPTO_LLAMA_KIND;
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
