// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for CurveSwapper_v1 against real mainnet Curve pools. Proves the executor can
// route through a Curve CRYPTO pool (uint256 indices) — TricryptoLLAMA — not only StableSwap
// (int128) pools, and documents the on-chain family facts the route config depends on.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {CurveSwapper_v1} from "@harbor-swap/executors/CurveSwapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {ConfigFxSaveWstEthRoute_ETH_mainnet as Cfg} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";
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

    /// @notice On-chain family facts the FxSave/Curve routes depend on: TricryptoLLAMA is a
    ///         CRYPTO pool (uint256 `exchange`, no int128); the fxSAVE/scrvUSD pool is
    ///         StableSwap (int128 `exchange`). This is the drift guard that a mis-encoded route
    ///         violates — a Curve crypto pool does NOT implement the int128 selector.
    function test_fork_curvePoolFamilies_matchExpectedSelectors() public view {
        assertTrue(
            _implementsSelector(Cfg.POOL_TRICRYPTO_LLAMA, EXCHANGE_UINT256),
            "TricryptoLLAMA must implement exchange(uint256,...)"
        );
        assertFalse(
            _implementsSelector(Cfg.POOL_TRICRYPTO_LLAMA, EXCHANGE_INT128),
            "TricryptoLLAMA must NOT implement exchange(int128,...)"
        );
        assertTrue(
            _implementsSelector(Cfg.POOL_FXSAVE_SCRVUSD, EXCHANGE_INT128),
            "fxSAVE/scrvUSD must implement exchange(int128,...)"
        );
    }

    /// @notice A real crvUSD -> wstETH swap through TricryptoLLAMA (a Curve CRYPTO pool) yields
    ///         wstETH within a tight band of the pool's own get_dy quote. RED against the
    ///         int128-only encoding (the crypto pool swallows that selector via its Vyper
    ///         __default__ and no-ops, so amountOut == 0); GREEN once the executor encodes the
    ///         uint256 `exchange` for crypto pools.
    function test_fork_swap_crvUsdToWstEth_throughTricrypto() public {
        uint256 amountIn = 1000 ether; // 1000 crvUSD
        deal(Cfg.CRVUSD, address(this), amountIn);

        CurveSwapper_v1(curveSwapperProxy).setRoute(
            Cfg.CRVUSD,
            Cfg.WSTETH,
            Cfg.POOL_TRICRYPTO_LLAMA,
            Cfg.POOL_TRICRYPTO_LLAMA_KIND,
            Cfg.POOL1_I_CRVUSD,
            Cfg.POOL1_J_WSTETH,
            false
        );

        uint256 expected = ICurveCryptoPoolView(Cfg.POOL_TRICRYPTO_LLAMA).get_dy(
            uint256(int256(Cfg.POOL1_I_CRVUSD)),
            uint256(int256(Cfg.POOL1_J_WSTETH)),
            amountIn
        );
        assertGt(expected, 0, "sanity: pool quotes a non-zero wstETH out");

        IERC20(Cfg.CRVUSD).approve(curveSwapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(Cfg.CRVUSD, Cfg.WSTETH, amountIn, 0);

        // Executed swap must land the quoted wstETH (small band for the block gap between the
        // get_dy read and the exchange). RED today: amountOut == 0 (silent no-op).
        assertApproxEqRel(amountOut, expected, 0.001e18, "wstETH out must match the pool quote");
        assertEq(IERC20(Cfg.WSTETH).balanceOf(address(this)), amountOut, "wstETH delivered to caller");
        assertEq(IERC20(Cfg.CRVUSD).balanceOf(curveSwapperProxy), 0, "no crvUSD stranded in adapter");
    }
}
