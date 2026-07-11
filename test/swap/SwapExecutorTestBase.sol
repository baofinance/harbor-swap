// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Shared behaviour suite for the swap-envelope invariants every executor must uphold
// (SwapExecutorBase): same-token rejection, zero-output rejection, the exact-minAmountOut
// boundary, and donation isolation. Inherited by each executor's test contract; the hooks
// bind the suite to that executor's venue mock and default token pair.

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";

abstract contract SwapExecutorTestBase is Test {
    /// @dev The executor (proxy) under test.
    function _swapExecutorTarget() internal view virtual returns (address);

    /// @dev The default configured pair for this executor's venue mock. Both must be
    ///      mintable MockERC20s at 1:1 venue rate by default.
    function _swapFromToken() internal view virtual returns (address);

    function _swapToToken() internal view virtual returns (address);

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

    function _fundAndApprove(address token, uint256 amount) private {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(_swapExecutorTarget(), amount);
    }

    /// @notice fromToken == toToken is a caller bug: reverts SameToken, never a passthrough
    ///         and never a venue-specific error.
    function test_swapExecutor_sameToken_reverts() public {
        uint256 amountIn = 1 ether;
        address token = _swapFromToken();
        _fundAndApprove(token, amountIn);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.SameToken.selector, token));
        _swapCall(token, token, amountIn, 0);
    }

    /// @notice A venue that produces nothing while reporting success (silent no-op) reverts
    ///         ZeroAmountOut even when minAmountOut is 0 — the guard that turns the
    ///         permissive-fallback failure mode from silent fund loss into a revert.
    function test_swapExecutor_zeroOutput_reverts() public {
        uint256 amountIn = 1 ether;
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());
        _setVenueRate(0);

        vm.expectRevert(SwapExecutorBase.ZeroAmountOut.selector);
        _swapCall(_swapFromToken(), _swapToToken(), amountIn, 0);
    }

    /// @notice amountOut exactly equal to minAmountOut succeeds — pins the >= boundary so an
    ///         off-by-one in the comparison cannot creep in.
    function test_swapExecutor_exactMinAmountOut_succeeds() public {
        uint256 amountIn = 1 ether;
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());

        uint256 amountOut = _swapCall(_swapFromToken(), _swapToToken(), amountIn, amountIn);

        assertEq(amountOut, amountIn, "1:1 venue rate delivers exactly minAmountOut");
        assertEq(IERC20(_swapToToken()).balanceOf(address(this)), amountOut, "delivered to caller");
    }

    /// @notice A donated toToken balance sitting in the executor is not paid out to the
    ///         caller: the caller receives only the swap's own output delta and the donation
    ///         stays in the executor (recoverable via sweep).
    function test_swapExecutor_donatedToToken_notPaidToCaller() public {
        uint256 amountIn = 1 ether;
        uint256 donation = 0.5 ether;
        MockERC20(_swapToToken()).mint(_swapExecutorTarget(), donation);
        _fundAndApprove(_swapFromToken(), amountIn);
        _prepareSwapPair(_swapFromToken(), _swapToToken());

        uint256 amountOut = _swapCall(_swapFromToken(), _swapToToken(), amountIn, 0);

        assertEq(amountOut, amountIn, "donation not swept into output");
        assertEq(IERC20(_swapToToken()).balanceOf(address(this)), amountOut, "caller got only the delta");
        assertEq(IERC20(_swapToToken()).balanceOf(_swapExecutorTarget()), donation, "donation untouched");
    }
}
