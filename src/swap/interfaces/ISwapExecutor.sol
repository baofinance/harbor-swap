// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapExecutor
/// @notice Interface implemented by DEX-specific swap executor contracts (e.g. UniV3Swapper_v1).
///         HarborYield calls this directly, using the address returned by ISwapper.getRoutesFrom.
interface ISwapExecutor {
    /// @notice Execute a token swap. Pulls fromToken from msg.sender and delivers toToken to msg.sender.
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @param amountIn Amount of fromToken to swap.
    /// @param minAmountOut Minimum acceptable output; reverts if not met.
    /// @return amountOut Actual amount of toToken delivered to msg.sender.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);
}
