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
import {ConfigFxSaveWstEthRoute_ETH_mainnet} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";

/// @title FxSaveWstEthSwapper_v1
/// @notice Composite `ISwapExecutor` for the peg-critical fxSAVE ↔ wstETH routes on Ethereum
///         mainnet.
/// @dev Forward (Harbor `distribute()` Phase 3): fxSAVE → scrvUSD shares → redeem → crvUSD →
///      USDC (Curve) → WETH → wstETH (UniV3). Reverse: wstETH → WETH → USDC → crvUSD →
///      scrvUSD deposit → fxSAVE. Route constants live in
///      `ConfigFxSaveWstEthRoute_ETH_mainnet`. Only `(FXSAVE, WSTETH)` and `(WSTETH, FXSAVE)`
///      are supported. The SwapExecutorBase envelope enforces slippage on the final output;
///      intermediate legs use `min_dy` / `amountOutMinimum = 0` and measure outputs as
///      balance deltas so donated balances are never swept through the route.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence
contract FxSaveWstEthSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);
    error VaultRedeemFailed();
    error VaultDepositFailed();

    /// @notice Emitted mid-route on every composite swap.
    /// @param intermediateAmount crvUSD after vault redeem (forward) or after USDC→crvUSD
    ///        (reverse). The final output is the swap's return value (and the envelope's
    ///        Transfer to the caller), so it is not repeated here.
    event FxSaveWstEthSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 intermediateAmount
    );

    ISwapRouter public immutable ROUTER;

    /// @custom:oz-upgrades-unsafe-allow constructor
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
        ROUTER.exactInput(
            ISwapRouter.ExactInputParams({
                path: _uniPathUsdcToWstEth(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcOut,
                amountOutMinimum: minAmountOut
            })
        );
        IERC20(_usdc()).forceApprove(address(ROUTER), 0);
    }

    function _executeWstEthToFxSave(uint256 amountIn, uint256 minAmountOut) private {
        uint256 usdcBefore = IERC20(_usdc()).balanceOf(address(this));

        IERC20(_wstEth()).forceApprove(address(ROUTER), amountIn);
        // slither-disable-next-line unused-return — intermediate USDC is measured as a balance delta
        ROUTER.exactInput(
            ISwapRouter.ExactInputParams({
                path: _uniPathWstEthToUsdc(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            })
        );
        IERC20(_wstEth()).forceApprove(address(ROUTER), 0);

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

    function _usdc() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.USDC;
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

    function _poolCrvUsdUsdc() internal view virtual returns (address) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_CRVUSD_USDC;
    }

    function _poolCrvUsdUsdcKind() internal view virtual returns (CurveExchangeLib.CurvePoolKind) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_CRVUSD_USDC_KIND;
    }

    function _pool2IFxSave() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL2_I_FXSAVE;
    }

    function _pool2JScrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL2_J_SCRVUSD;
    }

    function _poolUsdIUsdc() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_USD_I_USDC;
    }

    function _poolUsdJCrvUsd() internal view virtual returns (int128) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.POOL_USD_J_CRVUSD;
    }

    function _uniPathUsdcToWstEth() internal view virtual returns (bytes memory) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.uniPathUsdcToWstEth();
    }

    function _uniPathWstEthToUsdc() internal view virtual returns (bytes memory) {
        return ConfigFxSaveWstEthRoute_ETH_mainnet.uniPathWstEthToUsdc();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
