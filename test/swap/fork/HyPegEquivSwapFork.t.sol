// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork E2E: fxSAVE → WBTC and fxSAVE → LBTC on real mainnet venues.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {ConfigFxSaveWbtcRoute_ETH_mainnet as WbtcCfg} from "@harbor-swap/config/ConfigFxSaveWbtcRoute_ETH_mainnet.sol";
import {ConfigFxSaveLbtcRoute_ETH_mainnet as LbtcCfg} from "@harbor-swap/config/ConfigFxSaveLbtcRoute_ETH_mainnet.sol";
import {ConfigSwap_ETH_mainnet} from "@harbor-swap-script/config/ConfigSwap_ETH_mainnet.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface ICurveStableSwapView {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface ICurveCryptoView {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

interface IQuoterV1 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

contract HyPegEquivSwapForkTest is ForkTestBase, Swapper, ConfigSwap_ETH_mainnet {
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
    string constant SALT_PREFIX = "fork_hy_peg_swap";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        deployFxSaveWbtcSwapper(state);
        deployFxSaveLbtcSwapper(state);
        fxSaveWbtc = _predictAddress("fxSaveWbtcSwapper");
        fxSaveLbtc = _predictAddress("fxSaveLbtcSwapper");
    }

    function _quoteFxSaveToWbtc(uint256 fxSaveIn) internal view returns (uint256 wbtcOut) {
        uint256 shares = ICurveStableSwapView(WbtcCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            WbtcCfg.POOL2_I_FXSAVE,
            WbtcCfg.POOL2_J_SCRVUSD,
            fxSaveIn
        );
        uint256 crvUsd = IERC4626(WbtcCfg.SCRVUSD_VAULT).previewRedeem(shares);
        wbtcOut = ICurveCryptoView(WbtcCfg.POOL_CRVUSD_WBTC).get_dy(
            uint256(int256(WbtcCfg.POOL_BTC_I_CRVUSD)),
            uint256(int256(WbtcCfg.POOL_BTC_J_WBTC)),
            crvUsd
        );
    }

    function _quoteFxSaveToLbtc(uint256 fxSaveIn) internal returns (uint256 lbtcOut) {
        uint256 wbtcOut = _quoteFxSaveToWbtc(fxSaveIn);
        lbtcOut = IQuoterV1(QUOTER_V1).quoteExactInputSingle(
            LbtcCfg.WBTC,
            LbtcCfg.LBTC,
            LbtcCfg.UNI_WBTC_LBTC_FEE,
            wbtcOut,
            0
        );
    }

    function test_fork_swap_fxSaveToWbtc_executes() public {
        uint256 amountIn = 100 ether;
        deal(WbtcCfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteFxSaveToWbtc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(WbtcCfg.FXSAVE).approve(fxSaveWbtc, amountIn);
        uint256 minOut = (expected * 99) / 100;
        uint256 amountOut = ISwapExecutor(fxSaveWbtc).swap(WbtcCfg.FXSAVE, WbtcCfg.WBTC, amountIn, minOut);

        assertApproxEqRel(amountOut, expected, 0.002e18, "WBTC out must match composed quote");
        assertEq(IERC20(WbtcCfg.WBTC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(WbtcCfg.FXSAVE).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.CRVUSD).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.SCRVUSD_VAULT).balanceOf(fxSaveWbtc), 0);
        assertEq(IERC20(WbtcCfg.FXSAVE).allowance(fxSaveWbtc, WbtcCfg.POOL_FXSAVE_SCRVUSD), 0);
        assertEq(IERC20(WbtcCfg.CRVUSD).allowance(fxSaveWbtc, WbtcCfg.POOL_CRVUSD_WBTC), 0);
    }

    function test_fork_swap_fxSaveToLbtc_executes() public {
        uint256 amountIn = 100 ether;
        deal(LbtcCfg.FXSAVE, address(this), amountIn);

        uint256 expected = _quoteFxSaveToLbtc(amountIn);
        assertGt(expected, 0, "sanity: composed quote is non-zero");

        IERC20(LbtcCfg.FXSAVE).approve(fxSaveLbtc, amountIn);
        uint256 minOut = (expected * 99) / 100;
        uint256 amountOut = ISwapExecutor(fxSaveLbtc).swap(LbtcCfg.FXSAVE, LbtcCfg.LBTC, amountIn, minOut);

        assertApproxEqRel(amountOut, expected, 0.002e18, "LBTC out must match composed quote");
        assertEq(IERC20(LbtcCfg.LBTC).balanceOf(address(this)), amountOut);
        assertEq(IERC20(LbtcCfg.FXSAVE).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.WBTC).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.CRVUSD).balanceOf(fxSaveLbtc), 0);
        assertEq(IERC20(LbtcCfg.WBTC).allowance(fxSaveLbtc, UNIV3_ROUTER_MAINNET), 0);
    }
}
