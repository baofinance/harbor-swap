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
import {MockCurveStableSwapPool} from "@harbor-swap-test-mocks/MockCurveStableSwapPool.sol";
import {MockCurveCryptoPool} from "@harbor-swap-test-mocks/MockCurveCryptoPool.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IOwnable} from "@bao/interfaces/IOwnable.sol";
import {Token} from "@bao/Token.sol";
import {CurveSwapper_v1} from "@harbor-swap/executors/CurveSwapper_v1.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {UUPSOwnableTestBase} from "@bao-test/helpers/UUPSOwnableTestBase.t.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {MockFeeOnTransferERC20} from "@harbor-swap-test-mocks/MockFeeOnTransferERC20.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract CurveSwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, UUPSOwnableTestBase, Swapper {
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

    // ── SwapExecutor behaviour hooks ──────────────────────────────────
    function _swapExecutorTarget() internal view override returns (address) {
        return curveSwapperProxy;
    }
    function _swapFromToken() internal view override returns (address) {
        return fromToken;
    }
    function _swapToToken() internal view override returns (address) {
        return toToken;
    }
    function _prepareSwapPair(address fromToken_, address toToken_) internal override {
        MockCurveStableSwapPool(pool).setCoin(I, fromToken_);
        MockCurveStableSwapPool(pool).setCoin(J, toToken_);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken_,
            toToken_,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );
    }
    function _swapCall(
        address fromToken_,
        address toToken_,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal override returns (uint256) {
        return ISwapExecutor(curveSwapperProxy).swap(fromToken_, toToken_, amountIn, minAmountOut);
    }
    function _setVenueRate(uint256 rate) internal override {
        MockCurveStableSwapPool(pool).setRate(rate);
    }
    function _expectedOut(uint256 amountIn) internal view override returns (uint256) {
        return (amountIn * MockCurveStableSwapPool(pool).rate()) / 1e18;
    }
    function _setVenueLiar() internal override {
        MockCurveStableSwapPool(pool).setHonourMinDy(false);
        MockCurveStableSwapPool(pool).setRate(MockCurveStableSwapPool(pool).rate() / 2);
    }

    // ── UUPS behaviour hooks ──────────────────────────────────────────
    function _uupsProxyTarget() internal view override returns (address) {
        return curveSwapperProxy;
    }
    function _uupsNonOwner() internal view override returns (address) {
        return alice;
    }
    function _uupsCallInitialize(address target) internal override {
        CurveSwapper_v1(target).initialize(address(1), address(2));
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

    /// @dev Non-unity fixture rate with a DECIMALS GAP baked in: the pool quotes out-units
    ///      per in-unit ×1e18, and the fixture pairs are 18-decimals → 6-decimals (a
    ///      WETH→USDC-like direction, output-truncating). 1e18 in-units at $2237 →
    ///      2237e6 out-units, so the rate is 2237e6. No assertion can pass by an
    ///      `amountOut == amountIn` tautology or by assuming equal decimals.
    uint256 constant CURVE_RATE = 2237e6;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 6));
        underlyingFrom = address(new MockERC20("Underlying From", "UF", 18));
        underlyingTo = address(new MockERC20("Underlying To", "UT", 6));

        pool = address(new MockCurveStableSwapPool());
        MockCurveStableSwapPool(pool).setCoin(I, fromToken);
        MockCurveStableSwapPool(pool).setCoin(J, toToken);
        MockCurveStableSwapPool(pool).setUnderlying(I, underlyingFrom);
        MockCurveStableSwapPool(pool).setUnderlying(J, underlyingTo);
        MockCurveStableSwapPool(pool).setRate(CURVE_RATE);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployCurveSwapper(state);
        curveSwapperProxy = _predictAddress("curveSwapper");
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _configureRoute() internal {
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );
    }

    function _configureUnderlyingRoute() internal {
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            underlyingFrom,
            underlyingTo,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            true
        );
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice Configured plain route: `exchange` is invoked; the rate-scaled toToken output
    ///         arrives at the caller.
    function test_swap_exchange_happyPath() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, _expectedOut(amountIn), "pool-rate-scaled output");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    /// @notice `useUnderlying = true` routes through `exchange_underlying`.
    function test_swap_exchangeUnderlying_happyPath() public {
        _configureUnderlyingRoute();
        uint256 amountIn = 2 ether;
        _mintAndApprove(underlyingFrom, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(underlyingFrom, underlyingTo, amountIn, 0);

        assertEq(amountOut, _expectedOut(amountIn), "pool-rate-scaled output");
        assertEq(IERC20(underlyingTo).balanceOf(address(this)), amountOut);
    }

    /// @notice Legacy 3pool-style pools return void; the executor must still recover
    ///         amountOut via balance delta.
    function test_swap_voidReturnPool_succeeds() public {
        _configureRoute();
        MockCurveStableSwapPool(pool).setReturnVoid(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        assertEq(amountOut, _expectedOut(amountIn), "pool-rate-scaled output despite void return");
    }

    /// @notice A Crypto-declared route through a crypto-family pool (uint256 `exchange`)
    ///         executes correctly — the family dispatch the general executor previously
    ///         could not route at all.
    function test_swap_cryptoPoolRoute_succeeds() public {
        address cryptoPool = address(new MockCurveCryptoPool());
        MockCurveCryptoPool(payable(cryptoPool)).setCoin(I, fromToken);
        MockCurveCryptoPool(payable(cryptoPool)).setCoin(J, toToken);
        MockCurveCryptoPool(payable(cryptoPool)).setRate(CURVE_RATE);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            cryptoPool,
            CurveExchangeLib.CurvePoolKind.Crypto,
            I,
            J,
            false
        );
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, (amountIn * CURVE_RATE) / 1e18, "crypto pool rate-scaled output");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
    }

    /// @notice A route mis-declared StableSwap while pointing at a CRYPTO pool sends the
    ///         int128 selector, which the pool's permissive fallback swallows as a silent
    ///         no-op — the envelope's ZeroAmountOut guard turns that into a revert instead
    ///         of silent fund loss. Mock-form regression pin of the mainnet TricryptoLLAMA
    ///         encoding defect.
    function test_swap_familyMisdeclaredStableSwap_revertsZeroAmountOut() public {
        address cryptoPool = address(new MockCurveCryptoPool());
        MockCurveCryptoPool(payable(cryptoPool)).setCoin(I, fromToken);
        MockCurveCryptoPool(payable(cryptoPool)).setCoin(J, toToken);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            cryptoPool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(SwapExecutorBase.ZeroAmountOut.selector);
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice A route mis-declared Crypto while pointing at a STABLESWAP pool sends the
    ///         uint256 selector, which the pool (no fallback, like the real NG pools)
    ///         rejects with an empty revert, surfaced as PoolCallFailed with empty inner
    ///         bytes.
    function test_swap_familyMisdeclaredCrypto_revertsPoolCallFailed() public {
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.Crypto,
            I,
            J,
            false
        );
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(CurveExchangeLib.PoolCallFailed.selector, bytes("")));
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice No configured route -> NoRouteConfigured.
    function test_swap_noRoute_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(CurveSwapper_v1.NoRouteConfigured.selector, fromToken, toToken));
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Pool's own min_dy enforcement reverts when minAmountOut exceeds the pool's
    ///         output (the executor forwards minAmountOut as min_dy for an early revert).
    function test_swap_slippage_reverts() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);
        // Hoisted: an argument sub-expression making an external call would steal the
        // expectRevert binding.
        uint256 rateTooHigh = _expectedRatePerUnitIn() + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "Slippage")
            )
        );
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, rateTooHigh);
    }

    /// @notice Pool revert is surfaced via PoolCallFailed.
    function test_swap_poolRevert_surfacesError() public {
        _configureRoute();
        MockCurveStableSwapPool(pool).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "MockCurvePool: forced revert")
            )
        );
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
        MockCurveStableSwapPool(pool).setReentrantCall(curveSwapperProxy, reentrantCall);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            )
        );
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
        assertEq(uint8(r.kind), uint8(CurveExchangeLib.CurvePoolKind.StableSwap));

        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            address(0),
            CurveExchangeLib.CurvePoolKind.StableSwap,
            0,
            0,
            false
        );
        r = CurveSwapper_v1(curveSwapperProxy).routes(fromToken, toToken);
        assertEq(r.pool, address(0));
    }

    /// @notice setRoute rejects i == j (invalid configuration).
    function test_setRoute_sameIndices_reverts() public {
        vm.expectRevert(CurveSwapper_v1.InvalidRoute.selector);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            1,
            1,
            false
        );
    }

    /// @notice setRoute rejects negative coin indices.
    function test_setRoute_negativeIndex_reverts() public {
        vm.expectRevert(CurveSwapper_v1.InvalidRoute.selector);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            -1,
            J,
            false
        );
    }

    /// @notice Non-owner / non-role address cannot call setRoute.
    function test_setRoute_calledByStranger_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(IOwnable.Unauthorized.selector);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );
        vm.stopPrank();
    }

    /// @notice Address granted ROUTE_SETTER_ROLE can call setRoute without owning.
    function test_setRoute_calledByRouteSetter_succeeds() public {
        CurveSwapper_v1(curveSwapperProxy).grantRoles(
            routeSetter,
            CurveSwapper_v1(curveSwapperProxy).ROUTE_SETTER_ROLE()
        );

        vm.startPrank(routeSetter);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );
        vm.stopPrank();

        assertEq(CurveSwapper_v1(curveSwapperProxy).routes(fromToken, toToken).pool, pool);
    }

    /// @notice setRoute emits the full RouteSet event, including the pool family.
    function test_setRoute_emitsRouteSet() public {
        vm.expectEmit(true, true, true, true);
        emit CurveSwapper_v1.RouteSet(fromToken, toToken, pool, CurveExchangeLib.CurvePoolKind.StableSwap, I, J, false);
        _configureRoute();
    }

    /// @notice setRoute rejects a pool address with no code.
    function test_setRoute_nonContractPool_reverts() public {
        address eoa = makeAddr("eoaPool");
        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, eoa));
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            eoa,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );
    }

    /// @notice Clearing a route (pool = 0) makes subsequent swaps revert NoRouteConfigured.
    function test_swap_afterRouteCleared_reverts() public {
        _configureRoute();
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fromToken,
            toToken,
            address(0),
            CurveExchangeLib.CurvePoolKind.StableSwap,
            0,
            0,
            false
        );
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, curveSwapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(CurveSwapper_v1.NoRouteConfigured.selector, fromToken, toToken));
        ISwapExecutor(curveSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice A fee-on-transfer fromToken delivers less than amountIn to the executor and is
    ///         rejected up front with UnexpectedAmountIn (exact expected/received amounts) —
    ///         never a wrapped pool error from the venue failing to pull the shortfall.
    function test_swap_feeOnTransferFromToken_reverts() public {
        uint256 feeBps = 100; // 1%
        address fot = address(new MockFeeOnTransferERC20("Fee Token", "FEE", feeBps));
        uint256 amountIn = 1 ether;
        MockFeeOnTransferERC20(fot).mint(address(this), amountIn);
        IERC20(fot).approve(curveSwapperProxy, amountIn);

        MockCurveStableSwapPool(pool).setCoin(I, fot);
        CurveSwapper_v1(curveSwapperProxy).setRoute(
            fot,
            toToken,
            pool,
            CurveExchangeLib.CurvePoolKind.StableSwap,
            I,
            J,
            false
        );

        uint256 received = amountIn - (amountIn * feeBps) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.UnexpectedAmountIn.selector, amountIn, received));
        ISwapExecutor(curveSwapperProxy).swap(fot, toToken, amountIn, 0);
    }
}
