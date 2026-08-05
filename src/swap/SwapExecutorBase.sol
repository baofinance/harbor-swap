// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SwapExecutorBase
/// @notice The swap envelope shared by every executor/adapter in this repo: pull the input,
///         run the venue-specific leg(s), measure the output as a balance delta, enforce the
///         output floor, refund unspent input, deliver proceeds to the caller.
/// @dev Invariants owned here, so no executor can drift from them individually:
///      - `fromToken == toToken` is a caller bug and reverts `SameToken` — no consumer ever
///        calls same-token (they short-circuit it), so a passthrough would only ever be an
///        unvalidated escape hatch.
///      - Exactly `amountIn` must arrive: fee-on-transfer / non-standard tokens revert
///        `UnexpectedAmountIn` up front instead of corrupting downstream accounting (or
///        failing later as an opaque arithmetic panic).
///      - The output is the `toToken` balance DELTA — pre-existing (donated) balances are
///        never paid out to the caller.
///      - `amountOut == 0` is ALWAYS fatal, independent of the floor. A venue with a
///        permissive fallback (e.g. a Vyper `__default__`) can accept a mis-encoded call,
///        do nothing, and return success — with a floor of 0 (which consumers legitimately
///        pass) the swap would otherwise consume the input and return nothing, silently.
///        A swap that produced nothing is a failed swap.
///      - The balance-delta check against `minAmountOut` is the AUTHORITATIVE slippage guard.
///        `minAmountOut` is the total demanded for the WHOLE order, and the check pro-rates it
///        by the fraction of that order actually SPENT. That is what
///        makes it survive the refund below: left unscaled it would reject an honest partial
///        fill, and scaled by the OUTPUT instead it would shrink in step with the very thing it
///        bounds and admit a sliver at any price. Pro-rating by the INPUT holds the demanded
///        price constant whatever fraction fills. Venues that accept a bound natively (Curve
///        `min_dy`) get `minAmountOut` verbatim as an early-revert optimisation; venues that
///        cannot (1inch opaque calldata) rely on this check alone.
///      - Unspent input (partial fills) is refunded to the caller, measured against the
///        pre-pull balance so pre-existing holdings are preserved, and underflow-free by
///        construction (the venue's approval is capped at `amountIn`).
///
///      This base is deliberately stateless and does NOT bundle Initializable /
///      UUPSUpgradeable / ownership / TokenHolder — each concrete executor composes those
///      directly (they have their own init and access needs). Concretes declare their
///      external `swap(...)` (ABIs differ, e.g. the aggregator takes router calldata), apply
///      `nonReentrant` there (the guard arrives via TokenHolder_v2), and call
///      `_swapEnvelope`, implementing only `_execute`.
abstract contract SwapExecutorBase {
    using SafeERC20 for IERC20;

    /// @notice A swap where `fromToken == toToken` — a caller bug, never a real swap.
    error SameToken(address token);

    /// @notice Pulling `amountIn` of `fromToken` delivered a different amount (fee-on-transfer
    ///         or otherwise non-standard token).
    error UnexpectedAmountIn(uint256 expected, uint256 received);

    /// @notice A swap of nothing. Rejected up front: it has no meaningful output, and the floor
    ///         is pro-rated by the fraction of the order spent, which a zero order cannot express.
    error ZeroAmountIn();

    /// @notice The venue produced no output at all — the call was a no-op or misrouted.
    error ZeroAmountOut();

    /// @notice The venue produced output below the caller's floor.
    error InsufficientAmountOut(uint256 amountOut, uint256 minAmountOut);

    /// @dev Run one swap through the envelope. `executeData` is passed through to `_execute`
    ///      verbatim for executors whose leg needs caller-supplied data (aggregator router
    ///      calldata); route-from-storage executors pass empty bytes. Also returns the
    ///      unspent-input `refundedIn` (non-zero on venue partial fills) for executors whose
    ///      events report it.
    function _swapEnvelope(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory executeData
    ) internal returns (uint256 amountOut, uint256 refundedIn) {
        if (fromToken == toToken) {
            revert SameToken(fromToken);
        }
        // Rejected here rather than left to the zero-output guard: that would report the wrong cause,
        // and `amountIn` is the denominator the floor is pro-rated by below.
        // slither-disable-next-line incorrect-equality — a zero-size order is exactly the guarded case
        if (amountIn == 0) {
            revert ZeroAmountIn();
        }

        uint256 fromBefore = IERC20(fromToken).balanceOf(address(this));
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(fromToken).balanceOf(address(this)) - fromBefore;
        if (received != amountIn) {
            revert UnexpectedAmountIn(amountIn, received);
        }

        uint256 toBefore = IERC20(toToken).balanceOf(address(this));

        // Venues that take a bound natively want the total for the whole order, which is exactly what
        // the caller passed — so it goes through verbatim, with no conversion to get wrong. It is
        // right for the exact-input venues that accept such a bound; a venue that fills partially
        // (the aggregator, whose opaque calldata carries no bound anyway) is caught by the
        // pro-rated check below instead.
        _execute(fromToken, toToken, amountIn, minAmountOut, executeData);

        amountOut = IERC20(toToken).balanceOf(address(this)) - toBefore;
        // Exact zero IS the guarded condition: a venue no-op produces exactly 0, and any
        // non-zero output proceeds to the floor check.
        // slither-disable-next-line incorrect-equality
        if (amountOut == 0) {
            revert ZeroAmountOut();
        }

        refundedIn = IERC20(fromToken).balanceOf(address(this)) - fromBefore;
        // The floor is the caller's total for the whole order, pro-rated by the fraction actually
        // SPENT — which is why it is measured after the refund. Judging the output against the
        // unscaled total would reject a partial fill that charged nothing at all; scaling by the
        // OUTPUT instead would let a sliver filled at any price through, since the floor would shrink
        // exactly as fast as the thing it bounds. Pro-rating by the INPUT holds the demanded price
        // constant however much fills. Rounded UP so a wei of flooring cannot buy slack.
        //
        // The denominator is the ORDER size, which is sound only because exactly `amountIn` arrived —
        // the equality check above. Relaxing that to tolerate fee-on-transfer tokens would not merely
        // skew the accounting, it would understate this floor by the fee and let that much slippage
        // through unnoticed.
        uint256 requiredOut = Math.mulDiv(amountIn - refundedIn, minAmountOut, amountIn, Math.Rounding.Ceil);
        if (amountOut < requiredOut) {
            revert InsufficientAmountOut(amountOut, requiredOut);
        }
        if (refundedIn > 0) {
            IERC20(fromToken).safeTransfer(msg.sender, refundedIn);
        }
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }

    /// @dev The venue-specific leg(s): spend up to `amountIn` of `fromToken` (already held by
    ///      this contract) to produce `toToken` back to this contract. Approvals to the venue
    ///      are granted and reset here. `minAmountOut` is the caller's total for the whole order,
    ///      passed through unchanged, and may be forwarded to venues that enforce a bound natively,
    ///      purely as an early revert; the envelope re-checks it authoritatively, pro-rated by what
    ///      was actually spent, either way.
    function _execute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory executeData
    ) internal virtual;
}
