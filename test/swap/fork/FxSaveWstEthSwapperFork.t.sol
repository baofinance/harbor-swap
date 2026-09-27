// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for FxSaveWstEthSwapper_v1 against the real mainnet route: fxSAVE/scrvUSD
// StableSwap-NG, scrvUSD vault, crvUSD/USDC StableSwap, and UniV3 USDC→WETH→wstETH.
// Verifies route config against on-chain state, executes both directions end-to-end with
// quote-composed expected amounts, and checks the final-leg slippage path.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {console2 as console} from "forge-std/console2.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {ForkUsdQuotes} from "@harbor-swap-test/fork/ForkUsdQuotes.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet as Cfg} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";
import {ConfigSwap_ETH_mainnet} from "@harbor-swap-script/config/ConfigSwap_ETH_mainnet.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface ICurveStableSwapView {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface ICurvePoolCoins {
    function coins(uint256 idx) external view returns (address);
}

interface IQuoterV1 {
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);

    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract FxSaveWstEthSwapperForkTest is ForkTestBase, ForkUsdQuotes, Swapper, ConfigSwap_ETH_mainnet {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return UNIV3_ROUTER_MAINNET;
    }

    address internal constant QUOTER_V1 = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address swapperProxy;
    string constant SALT_PREFIX = "fork_fxsave_wsteth";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        deployFxSaveWstEthSwapper(state);
        swapperProxy = _predictAddress("fxSaveWstEthSwapper");
    }

    function test_fork_route_coinsAndPoolsMatchConfig() public view {
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
        assertEq(
            ICurvePoolCoins(Cfg.POOL_CRVUSD_USDC).coins(uint256(int256(Cfg.POOL_USD_I_USDC))),
            Cfg.USDC,
            "crvUSD/USDC coin(I) must be USDC"
        );
        assertEq(
            ICurvePoolCoins(Cfg.POOL_CRVUSD_USDC).coins(uint256(int256(Cfg.POOL_USD_J_CRVUSD))),
            Cfg.CRVUSD,
            "crvUSD/USDC coin(J) must be crvUSD"
        );
        assertEq(IERC4626(Cfg.SCRVUSD_VAULT).asset(), Cfg.CRVUSD, "scrvUSD vault asset must be crvUSD");

        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(Cfg.USDC, Cfg.WETH, Cfg.UNI_USDC_WETH_FEE) != address(0),
            "USDC/WETH Uni pool"
        );
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(Cfg.WETH, Cfg.WSTETH, Cfg.UNI_WETH_WSTETH_FEE) != address(0),
            "WETH/wstETH Uni pool"
        );
        assertEq(Cfg.uniPathUsdcToWstEth().length, 20 + 3 + 20 + 3 + 20);
        assertEq(Cfg.uniPathWstEthToUsdc().length, 20 + 3 + 20 + 3 + 20);
    }

    /// @dev TEMP debug — remove after manual amount check.
    function _quoteForward(uint256 fxSaveIn) internal returns (uint256 wstEthOut) {
        uint256 shares = ICurveStableSwapView(Cfg.POOL_FXSAVE_SCRVUSD).get_dy(
            Cfg.POOL2_I_FXSAVE,
            Cfg.POOL2_J_SCRVUSD,
            fxSaveIn
        );
        uint256 crvUsd = IERC4626(Cfg.SCRVUSD_VAULT).previewRedeem(shares);
        uint256 usdc = ICurveStableSwapView(Cfg.POOL_CRVUSD_USDC).get_dy(
            Cfg.POOL_USD_J_CRVUSD,
            Cfg.POOL_USD_I_USDC,
            crvUsd
        );
        uint256 weth = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            Cfg.USDC, Cfg.WETH, Cfg.UNI_USDC_WETH_FEE, usdc, 0
        );
        wstEthOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            Cfg.WETH, Cfg.WSTETH, Cfg.UNI_WETH_WSTETH_FEE, weth, 0
        );

        console.log("--- fxSAVE -> wstETH quote legs ---");
        console.log("1 Curve fxSAVE/scrvUSD  in fxSAVE  ", fxSaveIn);
        console.log("                        out shares ", shares);
        console.log("2 vault redeem          in shares  ", shares);
        console.log("                        out crvUSD ", crvUsd);
        console.log("3 Curve crvUSD/USDC     in crvUSD  ", crvUsd);
        console.log("                        out USDC   ", usdc);
        console.log("4 Uni USDC/WETH 0.05%   in USDC    ", usdc);
        console.log("                        out WETH   ", weth);
        console.log("5 Uni WETH/wstETH 0.01% in WETH    ", weth);
        console.log("                        out wstETH ", wstEthOut);
    }

    /// @dev TEMP quote + amount logs (visible with `forge test -vv`).
    function _quoteReverse(uint256 wstEthIn) internal returns (uint256 fxSaveOut) {
        uint256 weth = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            Cfg.WSTETH, Cfg.WETH, Cfg.UNI_WETH_WSTETH_FEE, wstEthIn, 0
        );
        uint256 usdc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            Cfg.WETH, Cfg.USDC, Cfg.UNI_USDC_WETH_FEE, weth, 0
        );
        uint256 crvUsd = ICurveStableSwapView(Cfg.POOL_CRVUSD_USDC).get_dy(
            Cfg.POOL_USD_I_USDC,
            Cfg.POOL_USD_J_CRVUSD,
            usdc
        );
        uint256 shares = IERC4626(Cfg.SCRVUSD_VAULT).previewDeposit(crvUsd);
        fxSaveOut = ICurveStableSwapView(Cfg.POOL_FXSAVE_SCRVUSD).get_dy(
            Cfg.POOL2_J_SCRVUSD,
            Cfg.POOL2_I_FXSAVE,
            shares
        );

        console.log("--- wstETH -> fxSAVE quote legs ---");
        console.log("1 Uni wstETH/WETH 0.01% in wstETH  ", wstEthIn);
        console.log("                        out WETH   ", weth);
        console.log("2 Uni WETH/USDC 0.05%   in WETH    ", weth);
        console.log("                        out USDC   ", usdc);
        console.log("3 Curve USDC/crvUSD     in USDC    ", usdc);
        console.log("                        out crvUSD ", crvUsd);
        console.log("4 vault deposit         in crvUSD  ", crvUsd);
        console.log("                        out shares ", shares);
        console.log("5 Curve scrvUSD/fxSAVE  in shares  ", shares);
        console.log("                        out fxSAVE ", fxSaveOut);
    }

    function test_fork_swap_fxSaveToWstEth_executes() public {
        uint256 amountIn = 100 ether; // 100 fxSAVE
        deal(Cfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteForward(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(Cfg.FXSAVE).approve(swapperProxy, amountIn);
        uint256 minOut = (expected * 99) / 100;
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(Cfg.FXSAVE, Cfg.WSTETH, amountIn, minOut);

        _logExecuted(
            "amountIn  fxSAVE ",
            amountIn,
            _fxSaveUsd6(amountIn),
            "amountOut wstETH ",
            amountOut,
            _wstEthUsd6(amountOut),
            expected,
            _wstEthUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "wstETH out must match the composed quote");
        assertEq(IERC20(Cfg.WSTETH).balanceOf(address(this)), amountOut, "wstETH delivered to caller");

        assertEq(IERC20(Cfg.FXSAVE).balanceOf(swapperProxy), 0, "no fxSAVE residue");
        assertEq(IERC20(Cfg.SCRVUSD_VAULT).balanceOf(swapperProxy), 0, "no scrvUSD share residue");
        assertEq(IERC20(Cfg.CRVUSD).balanceOf(swapperProxy), 0, "no crvUSD residue");
        assertEq(IERC20(Cfg.USDC).balanceOf(swapperProxy), 0, "no USDC residue");
        assertEq(IERC20(Cfg.WSTETH).balanceOf(swapperProxy), 0, "no wstETH residue");

        assertEq(IERC20(Cfg.FXSAVE).allowance(swapperProxy, Cfg.POOL_FXSAVE_SCRVUSD), 0, "leg-1 approval cleared");
        assertEq(IERC20(Cfg.CRVUSD).allowance(swapperProxy, Cfg.POOL_CRVUSD_USDC), 0, "leg-3 approval cleared");
        assertEq(IERC20(Cfg.USDC).allowance(swapperProxy, UNIV3_ROUTER_MAINNET), 0, "uni approval cleared");
    }

    function test_fork_swap_wstEthToFxSave_executes() public {
        uint256 amountIn = 1 ether; // 1 wstETH
        deal(Cfg.WSTETH, address(this), amountIn);

        uint256 expected = _quoteReverse(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(Cfg.WSTETH).approve(swapperProxy, amountIn);
        uint256 minOut = (expected * 99) / 100;
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(Cfg.WSTETH, Cfg.FXSAVE, amountIn, minOut);

        _logExecuted(
            "amountIn  wstETH ",
            amountIn,
            _wstEthUsd6(amountIn),
            "amountOut fxSAVE ",
            amountOut,
            _fxSaveUsd6(amountOut),
            expected,
            _fxSaveUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "fxSAVE out must match the composed quote");
        assertEq(IERC20(Cfg.FXSAVE).balanceOf(address(this)), amountOut, "fxSAVE delivered to caller");

        assertEq(IERC20(Cfg.WSTETH).balanceOf(swapperProxy), 0, "no wstETH residue");
        assertEq(IERC20(Cfg.USDC).balanceOf(swapperProxy), 0, "no USDC residue");
        assertEq(IERC20(Cfg.CRVUSD).balanceOf(swapperProxy), 0, "no crvUSD residue");
        assertEq(IERC20(Cfg.SCRVUSD_VAULT).balanceOf(swapperProxy), 0, "no scrvUSD share residue");
        assertEq(IERC20(Cfg.FXSAVE).balanceOf(swapperProxy), 0, "no fxSAVE residue");
    }

    function test_fork_swap_aboveQuoteMinAmountOut_reverts() public {
        uint256 amountIn = 100 ether;
        deal(Cfg.FXSAVE, address(this), amountIn);
        uint256 expected = _quoteForward(amountIn);

        IERC20(Cfg.FXSAVE).approve(swapperProxy, amountIn);
        uint256 minTooHigh = (expected * 101) / 100;
        vm.expectRevert(bytes("Too little received"));
        ISwapExecutor(swapperProxy).swap(Cfg.FXSAVE, Cfg.WSTETH, amountIn, minTooHigh);
    }
}
