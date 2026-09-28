// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {Token} from "@bao/Token.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {ConfigFxSaveEurcRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveEurcRoute_ETH_mainnet.sol";

/// @title FxSaveEurcSwapper_v1
/// @notice One-way composite `ISwapExecutor` for fxSAVE → EURC (hyEUR peg-equiv).
/// @dev Legs: fxSAVE → scrvUSD → redeem → crvUSD → USDC (Curve) → EURC (UniV3).
///      Reverse via Velora. Router is an immutable constructor arg.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance
contract FxSaveEurcSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error VaultRedeemFailed();

    event FxSaveEurcSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 intermediateAmount
    );

    ISwapRouter public immutable ROUTER;

    constructor(address uniV3Router_) {
        _disableInitializers();
        ROUTER = ISwapRouter(uniV3Router_);
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
        if (fromToken != _fxSave() || toToken != _eurc()) {
            revert UnsupportedPair(fromToken, toToken);
        }

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

        emit FxSaveEurcSwap(msg.sender, _fxSave(), _eurc(), amountIn, crvUsdOut);

        uint256 usdcBefore = IERC20(_usdc()).balanceOf(address(this));
        _curveExchange(
            _poolCrvUsdUsdc(),
            _poolCrvUsdUsdcKind(),
            _poolUsdJCrvUsd(),
            _poolUsdIUsdc(),
            _crvUsd(),
            crvUsdOut,
            0
        );
        uint256 usdcOut = IERC20(_usdc()).balanceOf(address(this)) - usdcBefore;
        // slither-disable-next-line incorrect-equality
        if (usdcOut == 0) {
            revert Token.ZeroInputBalance(_usdc());
        }

        IERC20(_usdc()).forceApprove(address(ROUTER), usdcOut);
        // slither-disable-next-line unused-return — the envelope measures the output as a balance delta
        ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _usdc(),
                tokenOut: _eurc(),
                fee: _uniUsdcEurcFee(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcOut,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(_usdc()).forceApprove(address(ROUTER), 0);
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
        return ConfigFxSaveEurcRoute_ETH_mainnet.FXSAVE;
    }

    function _eurc() internal view virtual returns (address) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.EURC;
    }

    function _usdc() internal view virtual returns (address) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.USDC;
    }

    function _crvUsd() internal view virtual returns (address) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.CRVUSD;
    }

    function _scrvUsdVault() internal view virtual returns (address) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.SCRVUSD_VAULT;
    }

    function _poolFxSaveScrvUsd() internal view virtual returns (address) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD;
    }

    function _poolFxSaveScrvUsdKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD_KIND;
    }

    function _poolCrvUsdUsdc() internal view virtual returns (address) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL_CRVUSD_USDC;
    }

    function _poolCrvUsdUsdcKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL_CRVUSD_USDC_KIND;
    }

    function _pool2IFxSave() internal view virtual returns (int128) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL2_I_FXSAVE;
    }

    function _pool2JScrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL2_J_SCRVUSD;
    }

    function _poolUsdIUsdc() internal view virtual returns (int128) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL_USD_I_USDC;
    }

    function _poolUsdJCrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.POOL_USD_J_CRVUSD;
    }

    function _uniUsdcEurcFee() internal view virtual returns (uint24) {
        return ConfigFxSaveEurcRoute_ETH_mainnet.UNI_USDC_EURC_FEE;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
