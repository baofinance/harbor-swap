// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for FxSaveWstEthSwapper_v1 against the real mainnet route: the fxSAVE/scrvUSD
// StableSwap-NG pool, the scrvUSD ERC4626 vault, and the TricryptoLLAMA crypto pool. Verifies
// the route config against on-chain state (coins, vault asset), executes both composite
// directions end-to-end with quote-composed expected amounts, and checks the final-leg
// min_dy slippage path. This is the suite that a mis-declared pool family or a drifted
// route address fails.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet as Cfg} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface ICurveStableSwapView {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface ICurveCryptoView {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

interface ICurvePoolCoins {
    function coins(uint256 idx) external view returns (address);
}

contract FxSaveWstEthSwapperForkTest is ForkTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    address swapperProxy;
    string constant SALT_PREFIX = "fork_fxsave_wsteth";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        // No implementation override: the REAL FxSaveWstEthSwapper_v1 with the production
        // config constants is what these tests exercise.
        deployFxSaveWstEthSwapper(state);
        swapperProxy = _predictAddress("fxSaveWstEthSwapper");
    }

    /// @notice The route config matches on-chain reality: coin indices on both pools and the
    ///         vault's underlying asset. Guards against route-constant drift.
    function test_fork_route_coinsAndVaultMatchConfig() public view {
        assertEq(
            ICurvePoolCoins(Cfg.POOL_TRICRYPTO_LLAMA).coins(uint256(int256(Cfg.POOL1_I_CRVUSD))),
            Cfg.CRVUSD,
            "Tricrypto coin(I) must be crvUSD"
        );
        assertEq(
            ICurvePoolCoins(Cfg.POOL_TRICRYPTO_LLAMA).coins(uint256(int256(Cfg.POOL1_J_WSTETH))),
            Cfg.WSTETH,
            "Tricrypto coin(J) must be wstETH"
        );
        assertEq(
            ICurvePoolCoins(Cfg.POOL_FXSAVE_SCRVUSD).coins(uint256(int256(Cfg.POOL2_I_FXSAVE))),
            Cfg.FXSAVE,
            "fxSAVE pool coin(I) must be fxSAVE"
        );
        assertEq(
            ICurvePoolCoins(Cfg.POOL_FXSAVE_SCRVUSD).coins(uint256(int256(Cfg.POOL2_J_SCRVUSD))),
            Cfg.SCRVUSD_VAULT,
            "fxSAVE pool coin(J) must be the scrvUSD vault"
        );
        assertEq(IERC4626(Cfg.SCRVUSD_VAULT).asset(), Cfg.CRVUSD, "scrvUSD vault asset must be crvUSD");
    }

    /// @dev Compose the forward-route quote from the three legs' own on-chain views. All
    ///      quotes are taken at the same (pinned) block the legs execute in, and the legs hit
    ///      disjoint state (two different pools + the vault), so the composition is exact.
    function _quoteForward(uint256 fxSaveIn) internal view returns (uint256 wstEthOut) {
        uint256 shares = ICurveStableSwapView(Cfg.POOL_FXSAVE_SCRVUSD).get_dy(
            Cfg.POOL2_I_FXSAVE,
            Cfg.POOL2_J_SCRVUSD,
            fxSaveIn
        );
        uint256 crvUsd = IERC4626(Cfg.SCRVUSD_VAULT).previewRedeem(shares);
        wstEthOut = ICurveCryptoView(Cfg.POOL_TRICRYPTO_LLAMA).get_dy(
            uint256(int256(Cfg.POOL1_I_CRVUSD)),
            uint256(int256(Cfg.POOL1_J_WSTETH)),
            crvUsd
        );
    }

    /// @notice Forward composite (fxSAVE -> scrvUSD -> crvUSD -> wstETH) executes on the real
    ///         route and delivers the quote-composed wstETH to the caller with nothing left
    ///         in the adapter. RED while the Tricrypto leg is mis-encoded (silent no-op,
    ///         amountOut 0); GREEN with family-aware encoding.
    function test_fork_swap_fxSaveToWstEth_executes() public {
        uint256 amountIn = 100 ether; // 100 fxSAVE
        deal(Cfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteForward(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(Cfg.FXSAVE).approve(swapperProxy, amountIn);
        // The floor is a RATE — output per 1e18 of input — set 1% under the quote.
        uint256 minRate = (((expected * 1 ether) / amountIn) * 99) / 100;
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(Cfg.FXSAVE, Cfg.WSTETH, amountIn, minRate);

        assertApproxEqRel(amountOut, expected, 0.001e18, "wstETH out must match the composed quote");
        assertEq(IERC20(Cfg.WSTETH).balanceOf(address(this)), amountOut, "wstETH delivered to caller");

        assertEq(IERC20(Cfg.FXSAVE).balanceOf(swapperProxy), 0, "no fxSAVE residue");
        assertEq(IERC20(Cfg.SCRVUSD_VAULT).balanceOf(swapperProxy), 0, "no scrvUSD share residue");
        assertEq(IERC20(Cfg.CRVUSD).balanceOf(swapperProxy), 0, "no crvUSD residue");
        assertEq(IERC20(Cfg.WSTETH).balanceOf(swapperProxy), 0, "no wstETH residue");

        assertEq(IERC20(Cfg.FXSAVE).allowance(swapperProxy, Cfg.POOL_FXSAVE_SCRVUSD), 0, "leg-1 approval cleared");
        assertEq(IERC20(Cfg.CRVUSD).allowance(swapperProxy, Cfg.POOL_TRICRYPTO_LLAMA), 0, "leg-3 approval cleared");
    }

    /// @notice Reverse composite (wstETH -> crvUSD -> scrvUSD -> fxSAVE) executes on the real
    ///         route and delivers the quote-composed fxSAVE to the caller with nothing left in
    ///         the adapter.
    function test_fork_swap_wstEthToFxSave_executes() public {
        uint256 amountIn = 1 ether; // 1 wstETH
        deal(Cfg.WSTETH, address(this), amountIn);

        uint256 crvUsd = ICurveCryptoView(Cfg.POOL_TRICRYPTO_LLAMA).get_dy(
            uint256(int256(Cfg.POOL1_J_WSTETH)),
            uint256(int256(Cfg.POOL1_I_CRVUSD)),
            amountIn
        );
        uint256 shares = IERC4626(Cfg.SCRVUSD_VAULT).previewDeposit(crvUsd);
        uint256 expected = ICurveStableSwapView(Cfg.POOL_FXSAVE_SCRVUSD).get_dy(
            Cfg.POOL2_J_SCRVUSD,
            Cfg.POOL2_I_FXSAVE,
            shares
        );
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(Cfg.WSTETH).approve(swapperProxy, amountIn);
        // The floor is a RATE — output per 1e18 of input — set 1% under the quote.
        uint256 minRate = (((expected * 1 ether) / amountIn) * 99) / 100;
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(Cfg.WSTETH, Cfg.FXSAVE, amountIn, minRate);

        assertApproxEqRel(amountOut, expected, 0.001e18, "fxSAVE out must match the composed quote");
        assertEq(IERC20(Cfg.FXSAVE).balanceOf(address(this)), amountOut, "fxSAVE delivered to caller");

        assertEq(IERC20(Cfg.WSTETH).balanceOf(swapperProxy), 0, "no wstETH residue");
        assertEq(IERC20(Cfg.CRVUSD).balanceOf(swapperProxy), 0, "no crvUSD residue");
        assertEq(IERC20(Cfg.SCRVUSD_VAULT).balanceOf(swapperProxy), 0, "no scrvUSD share residue");
        assertEq(IERC20(Cfg.FXSAVE).balanceOf(swapperProxy), 0, "no fxSAVE residue");
    }

    /// @notice A minAmountOut above the composed quote reverts on the final leg: it is passed
    ///         to the real Tricrypto pool as min_dy, whose Vyper `"Slippage"` revert surfaces
    ///         wrapped in PoolCallFailed.
    function test_fork_swap_aboveQuoteMinAmountOut_reverts() public {
        uint256 amountIn = 100 ether;
        deal(Cfg.FXSAVE, address(this), amountIn);
        uint256 expected = _quoteForward(amountIn);

        IERC20(Cfg.FXSAVE).approve(swapperProxy, amountIn);
        // The floor is a RATE — output per 1e18 of input — so the quote is converted before being
        // pushed 1% above what the pools will actually pay.
        uint256 rateTooHigh = (((expected * 1 ether) / amountIn) * 101) / 100;
        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "Slippage")
            )
        );
        ISwapExecutor(swapperProxy).swap(Cfg.FXSAVE, Cfg.WSTETH, amountIn, rateTooHigh);
    }
}
