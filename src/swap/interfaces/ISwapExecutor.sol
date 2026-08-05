// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapExecutor
/// @notice Interface implemented by the venue-specific swap executor contracts in harbor-swap
///         (UniV3Swapper_v1, CurveSwapper_v1, …). HarborYield calls one directly, at the address
///         ISwapper.getRoutesFrom returned for the route.
interface ISwapExecutor {
    /// @notice Execute a token swap. Pulls fromToken from msg.sender and delivers toToken to msg.sender.
    ///         Unspent input is refunded, so `amountIn` is a limit rather than a promise.
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @param amountIn Amount of fromToken to swap, at most.
    /// @param minAmountOut Minimum acceptable output for the WHOLE order, in `toToken` units; reverts
    ///        if not met. Because unspent input is refunded, the floor is PRO-RATED by the fraction of
    ///        `amountIn` actually spent, so a partial fill must meet the same price rather than the
    ///        same total. Left unscaled it would reject an honest partial fill that charged nothing at
    ///        all; scaled by the OUTPUT it would shrink as fast as the thing it bounds and admit a
    ///        sliver at any price. Stated as a total, decimals are the caller's own and need no
    ///        conversion here.
    ///        0 disables the floor (a caller enforcing its own end-to-end bound).
    /// @return amountOut Actual amount of toToken delivered to msg.sender.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);
}
