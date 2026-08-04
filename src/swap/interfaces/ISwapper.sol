// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapper
/// @notice HarborYield-facing interface for querying available swap routes.
///         Swapper_v1 is a pure registry: it maps (from, to) → {swapExecutor, routeCostRatio}.
///         HarborYield batch-queries getRoutesFrom() once per distribute() call, then calls
///         the returned swapExecutor directly for each swap — no if/else in the dispatcher.
/// @dev Live pricing is done off-chain. At execute time HarborYield needs `routeCostRatio`
///      (configured via `setRoute`'s `feeRatio`) for cost / minting-threshold decisions. `amountIn` /
///      `amountOut` / `quoted` are ABI room for a future optional on-chain quote; Swapper_v1
///      always leaves `quoted = false` and `amountOut = 0`.
interface ISwapper {
    /// @notice Route availability, configured cost, and executor.
    struct RouteInfo {
        address target; // the target token queried
        bool available; // true iff a swap executor is configured for this pair
        uint256 routeCostRatio; // configured expected cost (fee + expected slippage); used at execute
        address swapExecutor; // ISwapExecutor to call directly (address(0) if unavailable)
    }

    /// @notice Batch-query route availability, optional quote, cost, and executor for
    ///         fromToken → each target. Result is index-aligned: routeInfos[i] ↔ targets[i].
    ///         O(N) storage reads in Swapper; one external call from HarborYield.
    /// @param fromToken Token to swap from.
    /// @param targets Array of target tokens to query.
    /// @return routeInfos Array of RouteInfo structs, one per target.
    function getRoutesFrom(
        address fromToken,
        address[] calldata targets
    ) external view returns (RouteInfo[] memory routeInfos);

    /// @notice Query a single registry route (convenience for tooling and one-off swaps).
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @return routeInfo Same shape as one element of `getRoutesFrom`.
    function getRoute(address fromToken, address toToken) external view returns (RouteInfo memory routeInfo);
}
