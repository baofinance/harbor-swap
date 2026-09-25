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
import {ConfigFxSaveWbtcRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveWbtcRoute_ETH_mainnet.sol";

/// @title FxSaveWbtcSwapper_v1
/// @notice Composite `ISwapExecutor` for fxSAVE ↔ WBTC on Ethereum mainnet (hyBTC out / hyUSD in).
/// @dev Forward: fxSAVE → scrvUSD → redeem → crvUSD → WBTC. Reverse: WBTC → crvUSD → deposit → fxSAVE.
// slither-disable-next-line missing-inheritance
contract FxSaveWbtcSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error VaultRedeemFailed();
    error VaultDepositFailed();

    event FxSaveWbtcSwap(
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

    function _execute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory
    ) internal override {
        if (fromToken == _fxSave() && toToken == _wbtc()) {
            _executeFxSaveToWbtc(amountIn, minAmountOut);
        } else if (fromToken == _wbtc() && toToken == _fxSave()) {
            _executeWbtcToFxSave(amountIn, minAmountOut);
        } else {
            revert UnsupportedPair(fromToken, toToken);
        }
    }

    function _executeFxSaveToWbtc(uint256 amountIn, uint256 minAmountOut) private {
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

        uint256 vaultShares = IERC20(_scrvUsdVault()).balanceOf(address(this)) - scrvUsdBefore;
        // slither-disable-next-line incorrect-equality
        if (vaultShares == 0) {
            revert Token.ZeroInputBalance(_scrvUsdVault());
        }

        uint256 crvUsdOut = IERC4626(_scrvUsdVault()).redeem(vaultShares, address(this), address(this));
        // slither-disable-next-line incorrect-equality
        if (crvUsdOut == 0) {
            revert VaultRedeemFailed();
        }

        emit FxSaveWbtcSwap(msg.sender, _fxSave(), _wbtc(), amountIn, crvUsdOut);

        _curveExchange(
            _poolCrvUsdWbtc(),
            _poolCrvUsdWbtcKind(),
            _poolBtcICrvUsd(),
            _poolBtcJWbtc(),
            _crvUsd(),
            crvUsdOut,
            minAmountOut
        );
    }

    function _executeWbtcToFxSave(uint256 amountIn, uint256 minAmountOut) private {
        uint256 crvUsdBefore = IERC20(_crvUsd()).balanceOf(address(this));

        _curveExchange(
            _poolCrvUsdWbtc(),
            _poolCrvUsdWbtcKind(),
            _poolBtcJWbtc(),
            _poolBtcICrvUsd(),
            _wbtc(),
            amountIn,
            0
        );

        uint256 crvUsdBal = IERC20(_crvUsd()).balanceOf(address(this)) - crvUsdBefore;
        // slither-disable-next-line incorrect-equality
        if (crvUsdBal == 0) {
            revert Token.ZeroInputBalance(_crvUsd());
        }

        emit FxSaveWbtcSwap(msg.sender, _wbtc(), _fxSave(), amountIn, crvUsdBal);

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
        return ConfigFxSaveWbtcRoute_ETH_mainnet.FXSAVE;
    }

    function _wbtc() internal view virtual returns (address) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.WBTC;
    }

    function _crvUsd() internal view virtual returns (address) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.CRVUSD;
    }

    function _scrvUsdVault() internal view virtual returns (address) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.SCRVUSD_VAULT;
    }

    function _poolFxSaveScrvUsd() internal view virtual returns (address) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD;
    }

    function _poolFxSaveScrvUsdKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD_KIND;
    }

    function _poolCrvUsdWbtc() internal view virtual returns (address) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL_CRVUSD_WBTC;
    }

    function _poolCrvUsdWbtcKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL_CRVUSD_WBTC_KIND;
    }

    function _pool2IFxSave() internal view virtual returns (int128) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL2_I_FXSAVE;
    }

    function _pool2JScrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL2_J_SCRVUSD;
    }

    function _poolBtcICrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL_BTC_I_CRVUSD;
    }

    function _poolBtcJWbtc() internal view virtual returns (int128) {
        return ConfigFxSaveWbtcRoute_ETH_mainnet.POOL_BTC_J_WBTC;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
