// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for CurveSwapper_v1 against real mainnet Curve pools. Proves the executor can
// route through a Curve CRYPTO pool (uint256 indices) — crvUSD/WBTC TwoCrypto — not only
// StableSwap (int128) pools, and documents the on-chain family facts crypto routes depend on.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {CurveSwapper_v1} from "@harbor-swap/executors/CurveSwapper_v1.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {ConfigFxSaveWbtcRoute_ETH_mainnet as Cfg} from "@harbor-swap/config/ConfigFxSaveWbtcRoute_ETH_mainnet.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface ICurveCryptoPoolView {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

contract CurveSwapperForkTest is ForkTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    bytes4 constant EXCHANGE_INT128 = 0x3df02124; // exchange(int128,int128,uint256,uint256)
    bytes4 constant EXCHANGE_UINT256 = 0x5b41b908; // exchange(uint256,uint256,uint256,uint256)

    address curveSwapperProxy;
    string constant SALT_PREFIX = "fork_curveswapper";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        deployCurveSwapper(state);
        curveSwapperProxy = _predictAddress("curveSwapper");
    }

    /// @notice On-chain family facts crypto routes depend on: TwoCrypto is CRYPTO (uint256
    ///         `exchange`, no int128); fxSAVE/scrvUSD is StableSwap (int128 `exchange`).
    function test_fork_curvePoolFamilies_matchExpectedSelectors() public view {
        assertTrue(
            _implementsSelector(Cfg.POOL_CRVUSD_WBTC, EXCHANGE_UINT256),
            "crvUSD/WBTC TwoCrypto must implement exchange(uint256,...)"
        );
        assertFalse(
            _implementsSelector(Cfg.POOL_CRVUSD_WBTC, EXCHANGE_INT128),
            "crvUSD/WBTC TwoCrypto must NOT implement exchange(int128,...)"
        );
        assertTrue(
            _implementsSelector(Cfg.POOL_FXSAVE_SCRVUSD, EXCHANGE_INT128),
            "fxSAVE/scrvUSD must implement exchange(int128,...)"
        );
        assertEq(uint8(Cfg.POOL_CRVUSD_WBTC_KIND), uint8(CurveExchangeLib.CurvePoolKind.Crypto));
    }

    /// @notice A real crvUSD -> WBTC swap through TwoCrypto yields WBTC within a tight band of
    ///         the pool's own get_dy quote. RED against int128-only encoding (crypto pools can
    ///         swallow that selector via Vyper __default__ and no-op); GREEN with uint256 encoding.
    function test_fork_swap_crvUsdToWbtc_throughTwoCrypto() public {
        uint256 amountIn = 1000 ether; // 1000 crvUSD
        deal(Cfg.CRVUSD, address(this), amountIn);

        CurveSwapper_v1(curveSwapperProxy).setRoute(
            Cfg.CRVUSD,
            Cfg.WBTC,
            Cfg.POOL_CRVUSD_WBTC,
            Cfg.POOL_CRVUSD_WBTC_KIND,
            Cfg.POOL_BTC_I_CRVUSD,
            Cfg.POOL_BTC_J_WBTC,
            false
        );

        uint256 expected = ICurveCryptoPoolView(Cfg.POOL_CRVUSD_WBTC).get_dy(
            uint256(int256(Cfg.POOL_BTC_I_CRVUSD)),
            uint256(int256(Cfg.POOL_BTC_J_WBTC)),
            amountIn
        );
        assertGt(expected, 0, "sanity: pool quotes a non-zero WBTC out");

        IERC20(Cfg.CRVUSD).approve(curveSwapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(Cfg.CRVUSD, Cfg.WBTC, amountIn, 0);

        assertApproxEqRel(amountOut, expected, 0.001e18, "WBTC out must match the pool quote");
        assertEq(IERC20(Cfg.WBTC).balanceOf(address(this)), amountOut, "WBTC delivered to caller");
        assertEq(IERC20(Cfg.CRVUSD).balanceOf(curveSwapperProxy), 0, "no crvUSD stranded in adapter");
    }
}
