// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests CurveSwapper_v1: Curve StableSwap-style routing via exchange/exchange_underlying,
// per-pair route config, approval cleanup, slippage protection, legacy void-return
// compatibility, role gate, and reentrancy guard. Uses the deploy script (Swapper.sol) so
// the CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockCurvePool} from "@harbor-swap-test-mocks/MockCurvePool.sol";

import {CurveSwapper_v1} from "@harbor-swap/executors/CurveSwapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract CurveSwapperTest is BaoTest, TokenHolderTestBase, Swapper {
    // ── FactoryDeployer abstracts ─────────────────────────────────────
    function owner() public view override returns (address) {
        return address(this);
    }
    function treasury() public view override returns (address) {
        return address(this);
    }
    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    // ── TokenHolder behaviour hooks ───────────────────────────────────
    function _tokenHolderTarget() internal view override returns (address) {
        return curveSwapperProxy;
    }
    function _tokenHolderSweepToken() internal view override returns (address) {
        return toToken;
    }
    function _tokenHolderNonOwner() internal view override returns (address) {
        return alice;
    }

    // ── Actors ───────────────────────────────────────────────────────
    address alice = makeAddr("alice");
    address routeSetter = makeAddr("routeSetter");

    // ── Tokens ───────────────────────────────────────────────────────
    address fromToken;
    address toToken;
    address underlyingFrom;
    address underlyingTo;

    // ── Infrastructure addresses ─────────────────────────────────────
    address pool;
    address curveSwapperProxy;

    string constant SALT_PREFIX = "test_curveswapper";
    int128 constant I = 0;
    int128 constant J = 1;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));
        underlyingFrom = address(new MockERC20("Underlying From", "UF", 18));
        underlyingTo = address(new MockERC20("Underlying To", "UT", 18));

        pool = address(new MockCurvePool());
        MockCurvePool(pool).setCoin(I, fromToken);
        MockCurvePool(pool).setCoin(J, toToken);
        MockCurvePool(pool).setUnderlying(I, underlyingFrom);
        MockCurvePool(pool).setUnderlying(J, underlyingTo);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployCurveSwapper(state);
        curveSwapperProxy = _predictAddress("curveSwapper");
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _configureRoute() internal {
        CurveSwapper_v1(curveSwapperProxy).setRoute(fromToken, toToken, pool, I, J, false);
    }

    function _configureUnderlyingRoute() internal {
        CurveSwapper_v1(curveSwapperProxy).setRoute(underlyingFrom, underlyingTo, pool, I, J, true);
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice Configured plain route: `exchange` is invoked; toToken arrives at caller.
    function test_swap_exchange_happyPath() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, amountIn, "MockCurvePool default rate 1:1");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    /// @notice `useUnderlying = true` routes through `exchange_underlying`.
    function test_swap_exchangeUnderlying_happyPath() public {
        _configureUnderlyingRoute();
        uint256 amountIn = 2 ether;
        _mintAndApprove(underlyingFrom, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(underlyingFrom, underlyingTo, amountIn, 0);

        assertEq(amountOut, amountIn);
        assertEq(IERC20(underlyingTo).balanceOf(address(this)), amountOut);
    }

    /// @notice Legacy 3pool-style pools return void; the executor must still recover
    ///         amountOut via balance delta.
    function test_swap_voidReturnPool_succeeds() public {
        _configureRoute();
        MockCurvePool(pool).setReturnVoid(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        assertEq(amountOut, amountIn);
    }

    /// @notice No configured route -> NoRouteConfigured.
    function test_swap_noRoute_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(CurveSwapper_v1.NoRouteConfigured.selector, fromToken, toToken));
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Pool's own min_dy enforcement reverts when rate is below the slippage floor.
    function test_swap_slippage_reverts() public {
        _configureRoute();
        MockCurvePool(pool).setRate(0.9e18);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(); // pool rejects below min_dy -> PoolCallFailed wraps
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 1 ether);
    }

    /// @notice Pool revert is surfaced via PoolCallFailed.
    function test_swap_poolRevert_surfacesError() public {
        _configureRoute();
        MockCurvePool(pool).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(); // PoolCallFailed wraps "MockCurvePool: forced revert"
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Pool allowance is cleared to zero after every swap.
    function test_swap_approvalsCleared() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        assertEq(IERC20(fromToken).allowance(curveSwapperProxy, pool), 0);
    }

    /// @notice fromToken pulled from msg.sender; toToken delivered to msg.sender.
    function test_swap_tokensTransferred() public {
        _configureRoute();
        uint256 amountIn = 3 ether;
        MockERC20(fromToken).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fromToken).approve(curveSwapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        vm.stopPrank();

        assertEq(IERC20(fromToken).balanceOf(alice), 0);
        assertEq(IERC20(toToken).balanceOf(alice), amountOut);
    }

    /// @notice Re-entrant call from the pool is blocked by nonReentrant.
    function test_swap_reentrancyGuard() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fromToken, toToken, amountIn, 0));
        MockCurvePool(pool).setReentrantCall(curveSwapperProxy, reentrantCall);

        vm.expectRevert();
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Route is stored and retrievable; clearing with pool=0 removes it.
    function test_setRoute_storeAndClear() public {
        _configureRoute();
        CurveSwapper_v1.CurveRoute memory r = CurveSwapper_v1(curveSwapperProxy).routes(fromToken, toToken);
        assertEq(r.pool, pool);
        assertEq(r.i, I);
        assertEq(r.j, J);
        assertFalse(r.useUnderlying);

        CurveSwapper_v1(curveSwapperProxy).setRoute(fromToken, toToken, address(0), 0, 0, false);
        r = CurveSwapper_v1(curveSwapperProxy).routes(fromToken, toToken);
        assertEq(r.pool, address(0));
    }

    /// @notice setRoute rejects i == j (invalid configuration).
    function test_setRoute_sameIndices_reverts() public {
        vm.expectRevert(CurveSwapper_v1.InvalidRoute.selector);
        CurveSwapper_v1(curveSwapperProxy).setRoute(fromToken, toToken, pool, 1, 1, false);
    }

    /// @notice Non-owner / non-role address cannot call setRoute.
    function test_setRoute_calledByStranger_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        CurveSwapper_v1(curveSwapperProxy).setRoute(fromToken, toToken, pool, I, J, false);
    }

    /// @notice Address granted ROUTE_SETTER_ROLE can call setRoute without owning.
    function test_setRoute_calledByRouteSetter_succeeds() public {
        CurveSwapper_v1(curveSwapperProxy).grantRoles(
            routeSetter,
            CurveSwapper_v1(curveSwapperProxy).ROUTE_SETTER_ROLE()
        );

        vm.prank(routeSetter);
        CurveSwapper_v1(curveSwapperProxy).setRoute(fromToken, toToken, pool, I, J, false);

        assertEq(CurveSwapper_v1(curveSwapperProxy).routes(fromToken, toToken).pool, pool);
    }
}
