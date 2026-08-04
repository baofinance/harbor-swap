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
    /// @param minAmountOutPerUnitIn Minimum acceptable RATE: `toToken` units per 1e18 units of
    ///        `fromToken` SPENT; reverts if not met. A rate rather than a total because unspent input is
    ///        refunded: an absolute floor would reject a partial fill that charged nothing at all, while
    ///        scaling that floor down by the fill would let a sliver filled at any price through. Only
    ///        the rate distinguishes a small honest fill from a bad one. Token decimals are the caller's
    ///        to fold in — the rate is quoted per 1e18 of input whatever `fromToken`'s decimals are.
    ///        0 disables the floor (a caller enforcing its own end-to-end bound).
    /// @return amountOut Actual amount of toToken delivered to msg.sender.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOutPerUnitIn
    ) external returns (uint256 amountOut);
}
