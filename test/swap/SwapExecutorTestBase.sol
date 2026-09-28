// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Shared behaviour suite for the swap-envelope invariants every executor must uphold
// (SwapExecutorBase): same-token rejection, zero-output rejection, the exact-minAmountOut
// boundary, and donation isolation. Inherited by each executor's test contract; the hooks
// bind the suite to that executor's venue mock and default token pair.

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";

abstract contract SwapExecutorTestBase is Test {
    /// @dev The executor (proxy) under test.
    function _swapExecutorTarget() internal view virtual returns (address);

    /// @dev The default configured pair for this executor's venue mock. Both must be
    ///      mintable MockERC20s; their decimals may differ (the generic-executor fixtures
    ///      deliberately mix 6 and 18) — amounts below are derived from the tokens' own
    ///      decimals.
    function _swapFromToken() internal view virtual returns (address);

    function _swapToToken() internal view virtual returns (address);

    /// @dev One whole unit of the fixture's fromToken (10^decimals).
    function _oneFromToken() private view returns (uint256) {
        return 10 ** MockERC20(_swapFromToken()).decimals();
    }

    /// @dev Half a whole unit of the fixture's toToken.
    function _halfToToken() private view returns (uint256) {
        return (10 ** MockERC20(_swapToToken()).decimals()) / 2;
    }

    /// @dev Venue-side setup for a distinct (fromToken, toToken) pair — e.g. configuring a
    ///      route on a routed executor. Called by tests BEFORE any `vm.expectRevert`, so
    ///      `_swapCall` must be a pure call with no preparatory external calls (expectRevert
    ///      binds to the next call). Default: nothing to prepare. Never called for
    ///      same-token, which must reach the executor unprepared.
    function _prepareSwapPair(address fromToken, address toToken) internal virtual {}

    /// @dev Perform the executor's swap for (fromToken, toToken) as the test contract —
    ///      each concrete encodes its own call shape (e.g. the aggregator builds router
    ///      calldata). Must be a SINGLE external call into the executor (tests wrap it in
    ///      `vm.expectRevert`); setup belongs in `_prepareSwapPair`. Must NOT approve or
    ///      fund; the tests do that.
    function _swapCall(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal virtual returns (uint256 amountOut);

    /// @dev Set the venue mock's output rate (1e18 = 1:1) for the default pair, including 0
    ///      (venue produces nothing and reports success — the silent no-op case).
    function _setVenueRate(uint256 rate) internal virtual;

    /// @dev The exact output the venue fixture will produce for `amountIn` on the default
    ///      pair at its CURRENT configuration — composed from the fixture's own rates /
    ///      preview functions, never hardcoded, so fixtures can (and do) use non-unity rates.
    function _expectedOut(uint256 amountIn) internal view virtual returns (uint256);

    /// @dev The absolute output the envelope demands when the venue spent `spent` of an order of
    ///      `amountIn` against a floor of `minAmountOut`, rounded up exactly as the envelope rounds
    ///      it — the value that appears in `InsufficientAmountOut`. A full fill (`spent == amountIn`)
    ///      demands `minAmountOut` itself, with no rounding applied at all.
    function _requiredOut(uint256 minAmountOut, uint256 spent, uint256 amountIn) internal pure returns (uint256) {
        return Math.mulDiv(spent, minAmountOut, amountIn, Math.Rounding.Ceil);
    }

    /// @dev Turn the venue into a "liar": it under-delivers relative to its current rate and
    ///      ignores any natively-enforced minimum, reporting success. Used to prove the
    ///      executor's own balance-delta floor is the guard that actually protects callers.
    function _setVenueLiar() internal virtual;

    function _fundAndApprove(address token, uint256 amount) private {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(_swapExecutorTarget(), amount);
    }

    /// @notice fromToken == toToken is a caller bug: reverts SameToken, never a passthrough
    ///         and never a venue-specific error.
    function test_swapExecutor_sameToken_reverts() public {
        uint256 amountIn = _oneFromToken();
        address token = _swapFromToken();
        _fundAndApprove(token, amountIn);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.SameToken.selector, token));
        _swapCall(token, token, amountIn, 0);
    }

    /// @notice A venue that produces nothing while reporting success (silent no-op) reverts
    ///         ZeroAmountOut even when minAmountOut is 0 — the guard that turns the
    ///         permissive-fallback failure mode from silent fund loss into a revert.
    function test_swapExecutor_zeroOutput_reverts() public {
        uint256 amountIn = _oneFromToken();
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());
        _setVenueRate(0);

        vm.expectRevert(SwapExecutorBase.ZeroAmountOut.selector);
        _swapCall(_swapFromToken(), _swapToToken(), amountIn, 0);
    }

    /// @notice amountOut exactly equal to minAmountOut succeeds — pins the >= boundary (at
    ///         the fixture's non-unity rate) so an off-by-one in the comparison cannot creep
    ///         in.
    function test_swapExecutor_exactMinAmountOut_succeeds() public {
        uint256 amountIn = _oneFromToken();
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());
        uint256 expected = _expectedOut(amountIn);

        uint256 amountOut = _swapCall(_swapFromToken(), _swapToToken(), amountIn, expected);

        assertEq(amountOut, expected, "venue delivers exactly the amount demanded");
        assertEq(IERC20(_swapToToken()).balanceOf(address(this)), amountOut, "delivered to caller");
    }

    /// @notice A zero-size order is rejected as such, rather than reaching the zero-output guard —
    ///         the right outcome for the wrong reason, and it would divide by zero when pro-rating
    ///         the floor.
    function test_swapExecutor_zeroAmountIn_reverts() public {
        _prepareSwapPair(_swapFromToken(), _swapToToken());

        vm.expectRevert(SwapExecutorBase.ZeroAmountIn.selector);
        _swapCall(_swapFromToken(), _swapToToken(), 0, 0);
    }

    /// @notice A venue that under-delivers WITHOUT reverting (ignoring any native minimum) is
    ///         caught by the executor's own balance-delta floor — the authoritative guard —
    ///         with the exact shortfall in the error. On a full fill the floor reported is the
    ///         caller's own number, unrounded: a floor expressed as a rate could not promise that,
    ///         since it must be scaled back up by the size and rounded before it can be enforced.
    function test_swapExecutor_belowMinAmountOut_reverts() public {
        uint256 amountIn = _oneFromToken();
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());
        uint256 required = _expectedOut(amountIn);

        _setVenueLiar();
        uint256 lied = _expectedOut(amountIn);
        assertLt(lied, required, "sanity: the liar under-delivers");

        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.InsufficientAmountOut.selector, lied, required));
        _swapCall(_swapFromToken(), _swapToToken(), amountIn, required);
    }

    /// @notice A donated toToken balance sitting in the executor is not paid out to the
    ///         caller: the caller receives only the swap's own output delta and the donation
    ///         stays in the executor (recoverable via sweep).
    function test_swapExecutor_donatedToToken_notPaidToCaller() public {
        uint256 amountIn = _oneFromToken();
        uint256 donation = _halfToToken();
        MockERC20(_swapToToken()).mint(_swapExecutorTarget(), donation);
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());
        uint256 expected = _expectedOut(amountIn);

        uint256 amountOut = _swapCall(_swapFromToken(), _swapToToken(), amountIn, 0);

        assertEq(amountOut, expected, "donation not swept into output");
        assertEq(IERC20(_swapToToken()).balanceOf(address(this)), amountOut, "caller got only the delta");
        assertEq(IERC20(_swapToToken()).balanceOf(_swapExecutorTarget()), donation, "donation untouched");
    }
}
