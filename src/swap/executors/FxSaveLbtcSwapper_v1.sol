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
import {ConfigFxSaveLbtcRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveLbtcRoute_ETH_mainnet.sol";

/// @title FxSaveLbtcSwapper_v1
/// @notice Composite `ISwapExecutor` for fxSAVE ↔ LBTC on Ethereum mainnet.
/// @dev Forward: fxSAVE → scrvUSD → redeem → crvUSD → USDC (Curve) → WBTC (Uni)
///        → LBTC (Uni). Reverse: LBTC → WBTC → USDC → crvUSD → deposit → fxSAVE.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance
contract FxSaveLbtcSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error VaultRedeemFailed();
    error VaultDepositFailed();

    event FxSaveLbtcSwap(
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
        if (fromToken == _fxSave() && toToken == _lbtc()) {
            _executeFxSaveToLbtc(amountIn, minAmountOut);
        } else if (fromToken == _lbtc() && toToken == _fxSave()) {
            _executeLbtcToFxSave(amountIn, minAmountOut);
        } else {
            revert UnsupportedPair(fromToken, toToken);
        }
    }

    function _executeFxSaveToLbtc(uint256 amountIn, uint256 minAmountOut) private {
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

        emit FxSaveLbtcSwap(msg.sender, _fxSave(), _lbtc(), amountIn, crvUsdOut);

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

        uint256 wbtcBefore = IERC20(_wbtc()).balanceOf(address(this));
        _uniExactInputSingle(_usdc(), _wbtc(), _uniUsdcWbtcFee(), usdcOut, 0);
        uint256 wbtcOut = IERC20(_wbtc()).balanceOf(address(this)) - wbtcBefore;
        // slither-disable-next-line incorrect-equality
        if (wbtcOut == 0) {
            revert Token.ZeroInputBalance(_wbtc());
        }

        _uniExactInputSingle(_wbtc(), _lbtc(), _uniWbtcLbtcFee(), wbtcOut, minAmountOut);
    }

    function _executeLbtcToFxSave(uint256 amountIn, uint256 minAmountOut) private {
        uint256 wbtcBefore = IERC20(_wbtc()).balanceOf(address(this));
        _uniExactInputSingle(_lbtc(), _wbtc(), _uniWbtcLbtcFee(), amountIn, 0);
        uint256 wbtcOut = IERC20(_wbtc()).balanceOf(address(this)) - wbtcBefore;
        // slither-disable-next-line incorrect-equality
        if (wbtcOut == 0) {
            revert Token.ZeroInputBalance(_wbtc());
        }

        uint256 usdcBefore = IERC20(_usdc()).balanceOf(address(this));
        _uniExactInputSingle(_wbtc(), _usdc(), _uniUsdcWbtcFee(), wbtcOut, 0);
        uint256 usdcOut = IERC20(_usdc()).balanceOf(address(this)) - usdcBefore;
        // slither-disable-next-line incorrect-equality
        if (usdcOut == 0) {
            revert Token.ZeroInputBalance(_usdc());
        }

        uint256 crvUsdBefore = IERC20(_crvUsd()).balanceOf(address(this));
        _curveExchange(
            _poolCrvUsdUsdc(),
            _poolCrvUsdUsdcKind(),
            _poolUsdIUsdc(),
            _poolUsdJCrvUsd(),
            _usdc(),
            usdcOut,
            0
        );
        uint256 crvUsdBal = IERC20(_crvUsd()).balanceOf(address(this)) - crvUsdBefore;
        // slither-disable-next-line incorrect-equality
        if (crvUsdBal == 0) {
            revert Token.ZeroInputBalance(_crvUsd());
        }

        emit FxSaveLbtcSwap(msg.sender, _lbtc(), _fxSave(), amountIn, crvUsdBal);

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

    function _uniExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) private {
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);
        // slither-disable-next-line unused-return — caller / envelope measures output as a balance delta
        ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(ROUTER), 0);
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
        return ConfigFxSaveLbtcRoute_ETH_mainnet.FXSAVE;
    }

    function _lbtc() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.LBTC;
    }

    function _wbtc() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.WBTC;
    }

    function _usdc() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.USDC;
    }

    function _crvUsd() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.CRVUSD;
    }

    function _scrvUsdVault() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.SCRVUSD_VAULT;
    }

    function _poolFxSaveScrvUsd() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD;
    }

    function _poolFxSaveScrvUsdKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL_FXSAVE_SCRVUSD_KIND;
    }

    function _poolCrvUsdUsdc() internal view virtual returns (address) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL_CRVUSD_USDC;
    }

    function _poolCrvUsdUsdcKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL_CRVUSD_USDC_KIND;
    }

    function _pool2IFxSave() internal view virtual returns (int128) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL2_I_FXSAVE;
    }

    function _pool2JScrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL2_J_SCRVUSD;
    }

    function _poolUsdIUsdc() internal view virtual returns (int128) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL_USD_I_USDC;
    }

    function _poolUsdJCrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.POOL_USD_J_CRVUSD;
    }

    function _uniUsdcWbtcFee() internal view virtual returns (uint24) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.UNI_USDC_WBTC_FEE;
    }

    function _uniWbtcLbtcFee() internal view virtual returns (uint24) {
        return ConfigFxSaveLbtcRoute_ETH_mainnet.UNI_WBTC_LBTC_FEE;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
