// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork conformance: hy peg-equiv route configs match on-chain Curve / UniV3 venues.

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {ConfigFxSaveWbtcRoute_ETH_mainnet as WbtcCfg} from "@harbor-swap/config/ConfigFxSaveWbtcRoute_ETH_mainnet.sol";
import {ConfigFxSaveLbtcRoute_ETH_mainnet as LbtcCfg} from "@harbor-swap/config/ConfigFxSaveLbtcRoute_ETH_mainnet.sol";
import {ConfigWstEthWbtcRoute_ETH_mainnet as WstWbtcCfg} from "@harbor-swap/config/ConfigWstEthWbtcRoute_ETH_mainnet.sol";
import {ConfigWstEthLbtcRoute_ETH_mainnet as WstLbtcCfg} from "@harbor-swap/config/ConfigWstEthLbtcRoute_ETH_mainnet.sol";
import {ConfigFxSaveEurcRoute_ETH_mainnet as EurcCfg} from "@harbor-swap/config/ConfigFxSaveEurcRoute_ETH_mainnet.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet as WstEthCfg} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";

interface ICurvePoolCoins {
    function coins(uint256 idx) external view returns (address);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract HyPegEquivRouteConfigForkTest is ForkTestBase {
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    function setUp() public {
        _forkMainnet();
    }

    function test_fork_fxSaveWbtc_coinsMatch() public view {
        assertEq(
            ICurvePoolCoins(WbtcCfg.POOL_CRVUSD_USDC).coins(uint256(int256(WbtcCfg.POOL_USD_I_USDC))),
            WbtcCfg.USDC
        );
        assertEq(
            ICurvePoolCoins(WbtcCfg.POOL_CRVUSD_USDC).coins(uint256(int256(WbtcCfg.POOL_USD_J_CRVUSD))),
            WbtcCfg.CRVUSD
        );
        assertEq(
            ICurvePoolCoins(WbtcCfg.POOL_FXSAVE_SCRVUSD).coins(uint256(int256(WbtcCfg.POOL2_I_FXSAVE))),
            WbtcCfg.FXSAVE
        );
        assertEq(IERC4626(WbtcCfg.SCRVUSD_VAULT).asset(), WbtcCfg.CRVUSD);
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(WbtcCfg.USDC, WbtcCfg.WBTC, WbtcCfg.UNI_USDC_WBTC_FEE) !=
                address(0),
            "USDC/WBTC Uni 0.05%"
        );
    }

    function test_fork_fxSaveLbtc_venuesExist() public view {
        assertEq(LbtcCfg.POOL_CRVUSD_USDC, WbtcCfg.POOL_CRVUSD_USDC, "LBTC shares Curve USD pool with WBTC route");
        assertEq(LbtcCfg.UNI_USDC_WBTC_FEE, WbtcCfg.UNI_USDC_WBTC_FEE, "LBTC shares Uni USDC/WBTC fee");
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(LbtcCfg.WBTC, LbtcCfg.LBTC, LbtcCfg.UNI_WBTC_LBTC_FEE) !=
                address(0),
            "WBTC/LBTC Uni 0.01%"
        );
    }

    function test_fork_wstEthWbtc_uniPathPoolsExist() public view {
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(
                WstWbtcCfg.WSTETH,
                WstWbtcCfg.WETH,
                WstWbtcCfg.UNI_WSTETH_WETH_FEE
            ) != address(0)
        );
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(WstWbtcCfg.WETH, WstWbtcCfg.WBTC, WstWbtcCfg.UNI_WETH_WBTC_FEE) !=
                address(0)
        );
        assertEq(WstWbtcCfg.uniPath().length, 20 + 3 + 20 + 3 + 20);
    }

    function test_fork_wstEthLbtc_uniPathPoolsExist() public view {
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(
                WstLbtcCfg.WSTETH,
                WstLbtcCfg.WETH,
                WstLbtcCfg.UNI_WSTETH_WETH_FEE
            ) != address(0)
        );
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(WstLbtcCfg.WETH, WstLbtcCfg.WBTC, WstLbtcCfg.UNI_WETH_WBTC_FEE) !=
                address(0)
        );
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(WstLbtcCfg.WBTC, WstLbtcCfg.LBTC, WstLbtcCfg.UNI_WBTC_LBTC_FEE) !=
                address(0)
        );
        assertEq(WstLbtcCfg.uniPath().length, 20 + 3 + 20 + 3 + 20 + 3 + 20);
    }

    function test_fork_fxSaveEurc_venuesMatch() public view {
        assertEq(
            ICurvePoolCoins(EurcCfg.POOL_CRVUSD_USDC).coins(uint256(int256(EurcCfg.POOL_USD_I_USDC))),
            EurcCfg.USDC
        );
        assertEq(
            ICurvePoolCoins(EurcCfg.POOL_CRVUSD_USDC).coins(uint256(int256(EurcCfg.POOL_USD_J_CRVUSD))),
            EurcCfg.CRVUSD
        );
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(EurcCfg.USDC, EurcCfg.EURC, EurcCfg.UNI_USDC_EURC_FEE) !=
                address(0),
            "USDC/EURC Uni 0.05%"
        );
    }

    function test_fork_fxSaveWstEth_uniPathPoolsExist() public view {
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(WstEthCfg.USDC, WstEthCfg.WETH, WstEthCfg.UNI_USDC_WETH_FEE) !=
                address(0)
        );
        assertTrue(
            IUniswapV3Factory(UNIV3_FACTORY).getPool(WstEthCfg.WETH, WstEthCfg.WSTETH, WstEthCfg.UNI_WETH_WSTETH_FEE) !=
                address(0)
        );
        assertEq(WstEthCfg.uniPathUsdcToWstEth().length, 20 + 3 + 20 + 3 + 20);
        assertEq(WstEthCfg.uniPathWstEthToUsdc().length, 20 + 3 + 20 + 3 + 20);
        assertEq(WstEthCfg.POOL_CRVUSD_USDC, EurcCfg.POOL_CRVUSD_USDC);
    }
}
