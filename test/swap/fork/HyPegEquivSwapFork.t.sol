// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork E2E + TEMP per-leg amount logs for hy peg-equiv routes:
//   fxSAVE ↔ WBTC / LBTC; fxSAVE → EURC
//   wstETH → WBTC / LBTC / EURC / fxSAVE
// Amount logs show with `forge test -vv` (hidden at default verbosity).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {console2 as console} from "forge-std/console2.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {ForkUsdQuotes} from "@harbor-swap-test/fork/ForkUsdQuotes.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";
import {ConfigFxSaveWbtcRoute_ETH_mainnet as WbtcCfg} from "@harbor-swap/config/ConfigFxSaveWbtcRoute_ETH_mainnet.sol";
import {ConfigFxSaveLbtcRoute_ETH_mainnet as LbtcCfg} from "@harbor-swap/config/ConfigFxSaveLbtcRoute_ETH_mainnet.sol";
import {ConfigFxSaveEurcRoute_ETH_mainnet as EurcCfg} from "@harbor-swap/config/ConfigFxSaveEurcRoute_ETH_mainnet.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet as WstCfg} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";
import {ConfigWstEthWbtcRoute_ETH_mainnet as WstWbtcCfg} from "@harbor-swap/config/ConfigWstEthWbtcRoute_ETH_mainnet.sol";
import {ConfigWstEthLbtcRoute_ETH_mainnet as WstLbtcCfg} from "@harbor-swap/config/ConfigWstEthLbtcRoute_ETH_mainnet.sol";
import {ConfigSwap_ETH_mainnet} from "@harbor-swap-script/config/ConfigSwap_ETH_mainnet.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface ICurveStableSwapView {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
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

contract HyPegEquivSwapForkTest is ForkTestBase, ForkUsdQuotes, Swapper, ConfigSwap_ETH_mainnet {
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

    address fxSaveWbtc;
    address fxSaveLbtc;
    address fxSaveEurc;
    address fxSaveWstEth;
    address wstEthWbtc;
    address wstEthLbtc;
    address uniV3;
    string constant SALT_PREFIX = "fork_hy_peg_swap";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        deployFxSaveWbtcSwapper(state);
        deployFxSaveLbtcSwapper(state);
        deployFxSaveEurcSwapper(state);
        deployFxSaveWstEthSwapper(state);
        deployWstEthWbtcSwapper(state);
        deployWstEthLbtcSwapper(state);
        deployUniV3Swapper(state);

        fxSaveWbtc = _predictAddress("fxSaveWbtcSwapper");
        fxSaveLbtc = _predictAddress("fxSaveLbtcSwapper");
        fxSaveEurc = _predictAddress("fxSaveEurcSwapper");
        fxSaveWstEth = _predictAddress("fxSaveWstEthSwapper");
        wstEthWbtc = _predictAddress("wstEthWbtcSwapper");
        wstEthLbtc = _predictAddress("wstEthLbtcSwapper");
        uniV3 = _predictAddress("uniV3Swapper");

        UniV3Swapper_v1(uniV3).setPath(WSTETH, EURC, _wstEthToEurcUniPath());
    }

    // ── TEMP quote helpers (per-leg raw logs) + executed-swap USD log ────────

    function _quoteFxSaveToWbtc(uint256 fxSaveIn) internal returns (uint256 wbtcOut) {
        uint256 shares = ICurveStableSwapView(WbtcCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            WbtcCfg.POOL2_I_FXSAVE,
            WbtcCfg.POOL2_J_SCRVUSD,
            fxSaveIn
        );
        uint256 crvUsd = IERC4626(WbtcCfg.SCRVUSD_VAULT).previewRedeem(shares);
        uint256 usdc = ICurveStableSwapView(WbtcCfg.POOL_CRVUSD_USDC).get_dy(
            WbtcCfg.POOL_USD_J_CRVUSD,
            WbtcCfg.POOL_USD_I_USDC,
            crvUsd
        );
        wbtcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WbtcCfg.USDC,
            WbtcCfg.WBTC,
            WbtcCfg.UNI_USDC_WBTC_FEE,
            usdc,
            0
        );

        console.log("--- fxSAVE -> WBTC quote legs ---");
        console.log("1 Curve fxSAVE/scrvUSD  in fxSAVE  ", fxSaveIn);
        console.log("                        out shares ", shares);
        console.log("2 vault redeem          in shares  ", shares);
        console.log("                        out crvUSD ", crvUsd);
        console.log("3 Curve crvUSD/USDC     in crvUSD  ", crvUsd);
        console.log("                        out USDC   ", usdc);
        console.log("4 Uni USDC/WBTC 0.05%   in USDC    ", usdc);
        console.log("                        out WBTC   ", wbtcOut);
    }

    function _quoteFxSaveToLbtc(uint256 fxSaveIn) internal returns (uint256 lbtcOut) {
        uint256 shares = ICurveStableSwapView(LbtcCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            LbtcCfg.POOL2_I_FXSAVE,
            LbtcCfg.POOL2_J_SCRVUSD,
            fxSaveIn
        );
        uint256 crvUsd = IERC4626(LbtcCfg.SCRVUSD_VAULT).previewRedeem(shares);
        uint256 usdc = ICurveStableSwapView(LbtcCfg.POOL_CRVUSD_USDC).get_dy(
            LbtcCfg.POOL_USD_J_CRVUSD,
            LbtcCfg.POOL_USD_I_USDC,
            crvUsd
        );
        uint256 wbtcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            LbtcCfg.USDC,
            LbtcCfg.WBTC,
            LbtcCfg.UNI_USDC_WBTC_FEE,
            usdc,
            0
        );
        lbtcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            LbtcCfg.WBTC,
            LbtcCfg.LBTC,
            LbtcCfg.UNI_WBTC_LBTC_FEE,
            wbtcOut,
            0
        );

        console.log("--- fxSAVE -> LBTC quote legs ---");
        console.log("1 Curve fxSAVE/scrvUSD  in fxSAVE  ", fxSaveIn);
        console.log("                        out shares ", shares);
        console.log("2 vault redeem          in shares  ", shares);
        console.log("                        out crvUSD ", crvUsd);
        console.log("3 Curve crvUSD/USDC     in crvUSD  ", crvUsd);
        console.log("                        out USDC   ", usdc);
        console.log("4 Uni USDC/WBTC 0.05%   in USDC    ", usdc);
        console.log("                        out WBTC   ", wbtcOut);
        console.log("5 Uni WBTC/LBTC 0.01%   in WBTC    ", wbtcOut);
        console.log("                        out LBTC   ", lbtcOut);
    }

    function _quoteFxSaveToEurc(uint256 fxSaveIn) internal returns (uint256 eurcOut) {
        uint256 shares = ICurveStableSwapView(EurcCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            EurcCfg.POOL2_I_FXSAVE,
            EurcCfg.POOL2_J_SCRVUSD,
            fxSaveIn
        );
        uint256 crvUsd = IERC4626(EurcCfg.SCRVUSD_VAULT).previewRedeem(shares);
        uint256 usdc = ICurveStableSwapView(EurcCfg.POOL_CRVUSD_USDC).get_dy(
            EurcCfg.POOL_USD_J_CRVUSD,
            EurcCfg.POOL_USD_I_USDC,
            crvUsd
        );
        eurcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            EurcCfg.USDC,
            EurcCfg.EURC,
            EurcCfg.UNI_USDC_EURC_FEE,
            usdc,
            0
        );

        console.log("--- fxSAVE -> EURC quote legs ---");
        console.log("1 Curve fxSAVE/scrvUSD  in fxSAVE  ", fxSaveIn);
        console.log("                        out shares ", shares);
        console.log("2 vault redeem          in shares  ", shares);
        console.log("                        out crvUSD ", crvUsd);
        console.log("3 Curve crvUSD/USDC     in crvUSD  ", crvUsd);
        console.log("                        out USDC   ", usdc);
        console.log("4 Uni USDC/EURC 0.05%   in USDC    ", usdc);
        console.log("                        out EURC   ", eurcOut);
    }

    function _quoteWstEthToWbtc(uint256 wstEthIn) internal returns (uint256 wbtcOut) {
        uint256 weth = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstWbtcCfg.WSTETH,
            WstWbtcCfg.WETH,
            WstWbtcCfg.UNI_WSTETH_WETH_FEE,
            wstEthIn,
            0
        );
        wbtcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstWbtcCfg.WETH,
            WstWbtcCfg.WBTC,
            WstWbtcCfg.UNI_WETH_WBTC_FEE,
            weth,
            0
        );

        console.log("--- wstETH -> WBTC quote legs ---");
        console.log("1 Uni wstETH/WETH 0.01% in wstETH  ", wstEthIn);
        console.log("                        out WETH   ", weth);
        console.log("2 Uni WETH/WBTC 0.05%   in WETH    ", weth);
        console.log("                        out WBTC   ", wbtcOut);
    }

    function _quoteWstEthToLbtc(uint256 wstEthIn) internal returns (uint256 lbtcOut) {
        uint256 weth = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstLbtcCfg.WSTETH,
            WstLbtcCfg.WETH,
            WstLbtcCfg.UNI_WSTETH_WETH_FEE,
            wstEthIn,
            0
        );
        uint256 wbtc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstLbtcCfg.WETH,
            WstLbtcCfg.WBTC,
            WstLbtcCfg.UNI_WETH_WBTC_FEE,
            weth,
            0
        );
        lbtcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstLbtcCfg.WBTC,
            WstLbtcCfg.LBTC,
            WstLbtcCfg.UNI_WBTC_LBTC_FEE,
            wbtc,
            0
        );

        console.log("--- wstETH -> LBTC quote legs ---");
        console.log("1 Uni wstETH/WETH 0.01% in wstETH  ", wstEthIn);
        console.log("                        out WETH   ", weth);
        console.log("2 Uni WETH/WBTC 0.05%   in WETH    ", weth);
        console.log("                        out WBTC   ", wbtc);
        console.log("3 Uni WBTC/LBTC 0.01%   in WBTC    ", wbtc);
        console.log("                        out LBTC   ", lbtcOut);
    }

    function _quoteWstEthToEurc(uint256 wstEthIn) internal returns (uint256 eurcOut) {
        uint256 weth = IQuoterV1(QUOTER_V1).quoteExactInputSingle(WSTETH, WETH, 100, wstEthIn, 0);
        uint256 usdc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(WETH, USDC, 500, weth, 0);
        eurcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(USDC, EURC, 500, usdc, 0);

        console.log("--- wstETH -> EURC quote legs ---");
        console.log("1 Uni wstETH/WETH 0.01% in wstETH  ", wstEthIn);
        console.log("                        out WETH   ", weth);
        console.log("2 Uni WETH/USDC 0.05%   in WETH    ", weth);
        console.log("                        out USDC   ", usdc);
        console.log("3 Uni USDC/EURC 0.05%   in USDC    ", usdc);
        console.log("                        out EURC   ", eurcOut);
    }

    function _quoteWstEthToFxSave(uint256 wstEthIn) internal returns (uint256 fxSaveOut) {
        uint256 weth = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstCfg.WSTETH,
            WstCfg.WETH,
            WstCfg.UNI_WETH_WSTETH_FEE,
            wstEthIn,
            0
        );
        uint256 usdc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WstCfg.WETH,
            WstCfg.USDC,
            WstCfg.UNI_USDC_WETH_FEE,
            weth,
            0
        );
        uint256 crvUsd = ICurveStableSwapView(WstCfg.POOL_CRVUSD_USDC).get_dy(
            WstCfg.POOL_USD_I_USDC,
            WstCfg.POOL_USD_J_CRVUSD,
            usdc
        );
        uint256 shares = IERC4626(WstCfg.SCRVUSD_VAULT).previewDeposit(crvUsd);
        fxSaveOut = ICurveStableSwapView(WstCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            WstCfg.POOL2_J_SCRVUSD,
            WstCfg.POOL2_I_FXSAVE,
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

    function _quoteWbtcToFxSave(uint256 wbtcIn) internal returns (uint256 fxSaveOut) {
        uint256 usdc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            WbtcCfg.WBTC,
            WbtcCfg.USDC,
            WbtcCfg.UNI_USDC_WBTC_FEE,
            wbtcIn,
            0
        );
        uint256 crvUsd = ICurveStableSwapView(WbtcCfg.POOL_CRVUSD_USDC).get_dy(
            WbtcCfg.POOL_USD_I_USDC,
            WbtcCfg.POOL_USD_J_CRVUSD,
            usdc
        );
        uint256 shares = IERC4626(WbtcCfg.SCRVUSD_VAULT).previewDeposit(crvUsd);
        fxSaveOut = ICurveStableSwapView(WbtcCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            WbtcCfg.POOL2_J_SCRVUSD,
            WbtcCfg.POOL2_I_FXSAVE,
            shares
        );

        console.log("--- WBTC -> fxSAVE quote legs ---");
        console.log("1 Uni USDC/WBTC 0.05%   in WBTC    ", wbtcIn);
        console.log("                        out USDC   ", usdc);
        console.log("2 Curve USDC/crvUSD     in USDC    ", usdc);
        console.log("                        out crvUSD ", crvUsd);
        console.log("3 vault deposit         in crvUSD  ", crvUsd);
        console.log("                        out shares ", shares);
        console.log("4 Curve scrvUSD/fxSAVE  in shares  ", shares);
        console.log("                        out fxSAVE ", fxSaveOut);
    }

    function _quoteLbtcToFxSave(uint256 lbtcIn) internal returns (uint256 fxSaveOut) {
        uint256 wbtc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            LbtcCfg.LBTC,
            LbtcCfg.WBTC,
            LbtcCfg.UNI_WBTC_LBTC_FEE,
            lbtcIn,
            0
        );
        uint256 usdc = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            LbtcCfg.WBTC,
            LbtcCfg.USDC,
            LbtcCfg.UNI_USDC_WBTC_FEE,
            wbtc,
            0
        );
        uint256 crvUsd = ICurveStableSwapView(LbtcCfg.POOL_CRVUSD_USDC).get_dy(
            LbtcCfg.POOL_USD_I_USDC,
            LbtcCfg.POOL_USD_J_CRVUSD,
            usdc
        );
        uint256 shares = IERC4626(LbtcCfg.SCRVUSD_VAULT).previewDeposit(crvUsd);
        fxSaveOut = ICurveStableSwapView(LbtcCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            LbtcCfg.POOL2_J_SCRVUSD,
            LbtcCfg.POOL2_I_FXSAVE,
            shares
        );

        console.log("--- LBTC -> fxSAVE quote legs ---");
        console.log("1 Uni WBTC/LBTC 0.01%   in LBTC    ", lbtcIn);
        console.log("                        out WBTC   ", wbtc);
        console.log("2 Uni USDC/WBTC 0.05%   in WBTC    ", wbtc);
        console.log("                        out USDC   ", usdc);
        console.log("3 Curve USDC/crvUSD     in USDC    ", usdc);
        console.log("                        out crvUSD ", crvUsd);
        console.log("4 vault deposit         in crvUSD  ", crvUsd);
        console.log("                        out shares ", shares);
        console.log("5 Curve scrvUSD/fxSAVE  in shares  ", shares);
        console.log("                        out fxSAVE ", fxSaveOut);
    }

    // ── fxSAVE → * ──────────────────────────────────────────────────────────

    function test_fork_swap_fxSaveToWbtc_executes() public {
        uint256 amountIn = 100 ether;
        deal(WbtcCfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteFxSaveToWbtc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WbtcCfg.FXSAVE).approve(fxSaveWbtc, amountIn);
        uint256 amountOut = ISwapExecutor(fxSaveWbtc).swap(
            WbtcCfg.FXSAVE,
            WbtcCfg.WBTC,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  fxSAVE ",
            amountIn,
            _fxSaveUsd6(amountIn),
            "amountOut WBTC   ",
            amountOut,
            _wbtcUsd6(amountOut),
            expected,
            _wbtcUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "WBTC out must match composed quote");
        assertEq(IERC20(WbtcCfg.WBTC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WbtcCfg.FXSAVE).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.USDC).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.CRVUSD).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.SCRVUSD_VAULT).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.FXSAVE).allowance(fxSaveWbtc, WbtcCfg.POOL_FXSAVE_SCRVUSD), 0);
        assertEq(IERC20(WbtcCfg.CRVUSD).allowance(fxSaveWbtc, WbtcCfg.POOL_CRVUSD_USDC), 0);
        assertEq(IERC20(WbtcCfg.USDC).allowance(fxSaveWbtc, UNIV3_ROUTER_MAINNET), 0);
    }

    function test_fork_swap_fxSaveToLbtc_executes() public {
        uint256 amountIn = 100 ether;
        deal(LbtcCfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteFxSaveToLbtc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(LbtcCfg.FXSAVE).approve(fxSaveLbtc, amountIn);
        uint256 amountOut = ISwapExecutor(fxSaveLbtc).swap(
            LbtcCfg.FXSAVE,
            LbtcCfg.LBTC,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  fxSAVE ",
            amountIn,
            _fxSaveUsd6(amountIn),
            "amountOut LBTC   ",
            amountOut,
            _lbtcUsd6(amountOut),
            expected,
            _lbtcUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "LBTC out must match composed quote");
        assertEq(IERC20(LbtcCfg.LBTC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(LbtcCfg.FXSAVE).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.WBTC).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.USDC).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.CRVUSD).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.SCRVUSD_VAULT).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.FXSAVE).allowance(fxSaveLbtc, LbtcCfg.POOL_FXSAVE_SCRVUSD), 0);
        assertEq(IERC20(LbtcCfg.CRVUSD).allowance(fxSaveLbtc, LbtcCfg.POOL_CRVUSD_USDC), 0);
        assertEq(IERC20(LbtcCfg.USDC).allowance(fxSaveLbtc, UNIV3_ROUTER_MAINNET), 0);
        assertEq(IERC20(LbtcCfg.WBTC).allowance(fxSaveLbtc, UNIV3_ROUTER_MAINNET), 0);
    }

    function test_fork_swap_wbtcToFxSave_executes() public {
        uint256 amountIn = 0.1e8; // 0.1 WBTC (8 decimals)
        deal(WbtcCfg.WBTC, address(this), amountIn);

        uint256 expected = _quoteWbtcToFxSave(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WbtcCfg.WBTC).approve(fxSaveWbtc, amountIn);
        uint256 amountOut = ISwapExecutor(fxSaveWbtc).swap(
            WbtcCfg.WBTC,
            WbtcCfg.FXSAVE,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  WBTC   ",
            amountIn,
            _wbtcUsd6(amountIn),
            "amountOut fxSAVE ",
            amountOut,
            _fxSaveUsd6(amountOut),
            expected,
            _fxSaveUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "fxSAVE out must match composed quote");
        assertEq(IERC20(WbtcCfg.FXSAVE).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WbtcCfg.WBTC).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.USDC).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.CRVUSD).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.SCRVUSD_VAULT).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.WBTC).allowance(fxSaveWbtc, UNIV3_ROUTER_MAINNET), 0);
        assertEq(IERC20(WbtcCfg.USDC).allowance(fxSaveWbtc, WbtcCfg.POOL_CRVUSD_USDC), 0);
        assertEq(IERC20(WbtcCfg.CRVUSD).allowance(fxSaveWbtc, WbtcCfg.SCRVUSD_VAULT), 0);
        assertEq(IERC20(WbtcCfg.SCRVUSD_VAULT).allowance(fxSaveWbtc, WbtcCfg.POOL_FXSAVE_SCRVUSD), 0);
    }

    function test_fork_swap_lbtcToFxSave_executes() public {
        uint256 amountIn = 0.1e8; // 0.1 LBTC (8 decimals)
        deal(LbtcCfg.LBTC, address(this), amountIn);

        uint256 expected = _quoteLbtcToFxSave(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(LbtcCfg.LBTC).approve(fxSaveLbtc, amountIn);
        uint256 amountOut = ISwapExecutor(fxSaveLbtc).swap(
            LbtcCfg.LBTC,
            LbtcCfg.FXSAVE,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  LBTC   ",
            amountIn,
            _lbtcUsd6(amountIn),
            "amountOut fxSAVE ",
            amountOut,
            _fxSaveUsd6(amountOut),
            expected,
            _fxSaveUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "fxSAVE out must match composed quote");
        assertEq(IERC20(LbtcCfg.FXSAVE).balanceOf(address(this)), amountOut);
        assertEq(IERC20(LbtcCfg.LBTC).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.WBTC).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.USDC).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.CRVUSD).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.SCRVUSD_VAULT).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.LBTC).allowance(fxSaveLbtc, UNIV3_ROUTER_MAINNET), 0);
        assertEq(IERC20(LbtcCfg.WBTC).allowance(fxSaveLbtc, UNIV3_ROUTER_MAINNET), 0);
        assertEq(IERC20(LbtcCfg.USDC).allowance(fxSaveLbtc, LbtcCfg.POOL_CRVUSD_USDC), 0);
        assertEq(IERC20(LbtcCfg.CRVUSD).allowance(fxSaveLbtc, LbtcCfg.SCRVUSD_VAULT), 0);
        assertEq(IERC20(LbtcCfg.SCRVUSD_VAULT).allowance(fxSaveLbtc, LbtcCfg.POOL_FXSAVE_SCRVUSD), 0);
    }

    function test_fork_swap_fxSaveToEurc_executes() public {
        uint256 amountIn = 100 ether;
        deal(EurcCfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteFxSaveToEurc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(EurcCfg.FXSAVE).approve(fxSaveEurc, amountIn);
        uint256 amountOut = ISwapExecutor(fxSaveEurc).swap(
            EurcCfg.FXSAVE,
            EurcCfg.EURC,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  fxSAVE ",
            amountIn,
            _fxSaveUsd6(amountIn),
            "amountOut EURC   ",
            amountOut,
            _eurcUsd6(amountOut),
            expected,
            _eurcUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "EURC out must match composed quote");
        assertEq(IERC20(EurcCfg.EURC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(EurcCfg.FXSAVE).balanceOf(fxSaveEurc), 0);
        assertEq(IERC20(EurcCfg.USDC).balanceOf(fxSaveEurc), 0);
        assertEq(IERC20(EurcCfg.CRVUSD).balanceOf(fxSaveEurc), 0);
        assertEq(IERC20(EurcCfg.USDC).allowance(fxSaveEurc, UNIV3_ROUTER_MAINNET), 0);
    }

    // ── wstETH → * ──────────────────────────────────────────────────────────

    function test_fork_swap_wstEthToWbtc_executes() public {
        uint256 amountIn = 1 ether;
        deal(WstWbtcCfg.WSTETH, address(this), amountIn);

        uint256 expected = _quoteWstEthToWbtc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WstWbtcCfg.WSTETH).approve(wstEthWbtc, amountIn);
        uint256 amountOut = ISwapExecutor(wstEthWbtc).swap(
            WstWbtcCfg.WSTETH,
            WstWbtcCfg.WBTC,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  wstETH ",
            amountIn,
            _wstEthUsd6(amountIn),
            "amountOut WBTC   ",
            amountOut,
            _wbtcUsd6(amountOut),
            expected,
            _wbtcUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "WBTC out must match composed quote");
        assertEq(IERC20(WstWbtcCfg.WBTC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WstWbtcCfg.WSTETH).balanceOf(wstEthWbtc), 0);
        assertEq(IERC20(WstWbtcCfg.WSTETH).allowance(wstEthWbtc, UNIV3_ROUTER_MAINNET), 0);
    }

    function test_fork_swap_wstEthToLbtc_executes() public {
        uint256 amountIn = 1 ether;
        deal(WstLbtcCfg.WSTETH, address(this), amountIn);

        uint256 expected = _quoteWstEthToLbtc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WstLbtcCfg.WSTETH).approve(wstEthLbtc, amountIn);
        uint256 amountOut = ISwapExecutor(wstEthLbtc).swap(
            WstLbtcCfg.WSTETH,
            WstLbtcCfg.LBTC,
            amountIn,
            (expected * 99) / 100
        );
        _logExecuted(
            "amountIn  wstETH ",
            amountIn,
            _wstEthUsd6(amountIn),
            "amountOut LBTC   ",
            amountOut,
            _lbtcUsd6(amountOut),
            expected,
            _lbtcUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "LBTC out must match composed quote");
        assertEq(IERC20(WstLbtcCfg.LBTC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WstLbtcCfg.WSTETH).balanceOf(wstEthLbtc), 0);
        assertEq(IERC20(WstLbtcCfg.WSTETH).allowance(wstEthLbtc, UNIV3_ROUTER_MAINNET), 0);
    }

    function test_fork_swap_wstEthToEurc_executes() public {
        uint256 amountIn = 1 ether;
        deal(WSTETH, address(this), amountIn);

        uint256 expected = _quoteWstEthToEurc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WSTETH).approve(uniV3, amountIn);
        uint256 amountOut = ISwapExecutor(uniV3).swap(WSTETH, EURC, amountIn, (expected * 99) / 100);
        _logExecuted(
            "amountIn  wstETH ",
            amountIn,
            _wstEthUsd6(amountIn),
            "amountOut EURC   ",
            amountOut,
            _eurcUsd6(amountOut),
            expected,
            _eurcUsd6(expected)
        );

        assertApproxEqRel(amountOut, expected, 0.002e18, "EURC out must match composed quote");
        assertEq(IERC20(EURC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WSTETH).balanceOf(uniV3), 0);
        assertEq(IERC20(USDC).balanceOf(uniV3), 0);
        assertEq(IERC20(WSTETH).allowance(uniV3, UNIV3_ROUTER_MAINNET), 0);
    }

    function test_fork_swap_wstEthToFxSave_executes() public {
        uint256 amountIn = 1 ether;
        deal(WstCfg.WSTETH, address(this), amountIn);

        uint256 expected = _quoteWstEthToFxSave(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WstCfg.WSTETH).approve(fxSaveWstEth, amountIn);
        uint256 amountOut = ISwapExecutor(fxSaveWstEth).swap(
            WstCfg.WSTETH,
            WstCfg.FXSAVE,
            amountIn,
            (expected * 99) / 100
        );
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

        assertApproxEqRel(amountOut, expected, 0.002e18, "fxSAVE out must match composed quote");
        assertEq(IERC20(WstCfg.FXSAVE).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WstCfg.WSTETH).balanceOf(fxSaveWstEth), 0);
        assertEq(IERC20(WstCfg.USDC).balanceOf(fxSaveWstEth), 0);
        assertEq(IERC20(WstCfg.CRVUSD).balanceOf(fxSaveWstEth), 0);
        assertEq(IERC20(WstCfg.SCRVUSD_VAULT).balanceOf(fxSaveWstEth), 0);
        assertEq(IERC20(WstCfg.FXSAVE).balanceOf(fxSaveWstEth), 0);
    }
}
