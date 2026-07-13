// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapper
/// @notice HY-facing interface for querying available swap routes.
///         Swapper_v1 is a pure registry: it maps (from, to) → {swapExecutor, feeRatio}.
///         HarborYield batch-queries getRoutesFrom() once per distribute() call, then calls
///         the returned swapExecutor directly for each swap — no if/else in the dispatcher.
interface ISwapper {
    /// @notice Route availability, fee, and executor address for a single token pair.
    struct RouteInfo {
        address target; // the target token queried
        bool available; // true iff a swap executor is configured for this pair
        uint256 feeRatio; // effective swap fee as a 1e18-scaled ratio (1e18 = 100%)
        address swapExecutor; // ISwapExecutor to call directly (address(0) if unavailable)
    }

    /// @notice Batch-query route availability, fee, and executor for fromToken → each target.
    ///         Result is index-aligned: routeInfos[i] corresponds to targets[i].
    ///         O(N) storage reads in Swapper; one external call from HY.
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
