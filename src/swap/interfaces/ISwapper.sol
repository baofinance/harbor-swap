// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapper
/// @notice HarborYield-facing interface for querying available swap routes.
///         Swapper_v1 is a pure registry: it maps (from, to) → {swapExecutor, routeCostRatio}.
///         HarborYield batch-queries getRoutesFrom() once per compound() pass, then calls the
///         returned swapExecutor directly for each swap — no if/else in the dispatcher.
/// @dev Live pricing is done off-chain. At execute time HarborYield needs `routeCostRatio`
///      (configured via `setRoute`) to price a route in its merit order.
///
///      `amountIn`, `amountOut` and `quoted` are RESERVED for an on-chain quote that does not exist
///      yet. `Swapper_v1` ignores `amountIn` and fills `amountOut = 0` / `quoted = false` for every
///      route, so a consumer MUST NOT branch on `quoted` — today that branch can never be taken. They
///      are declared now so the struct layout and both repos' copies are settled before the quote is
///      built, leaving that work purely additive.
interface ISwapper {
    /// @notice Route availability, optional live quote, configured cost, and executor.
    struct RouteInfo {
        address target; // the target token queried
        bool available; // true iff a swap executor is configured for this pair
        uint256 amountOut; // live quote for the queried amountIn; meaningless unless `quoted`
        bool quoted; // false ⇒ the route could not be priced on-chain; use routeCostRatio
        uint256 routeCostRatio; // configured expected cost (fee + expected slippage); used at execute
        address swapExecutor; // ISwapExecutor to call directly (address(0) if unavailable)
    }

    /// @notice Batch-query route availability, cost, and executor for fromToken → each target.
    ///         Result is index-aligned: routeInfos[i] ↔ targets[i].
    ///         O(N) storage reads in Swapper; one external call from HarborYield.
    /// @param fromToken Token to swap from.
    /// @param targets Array of target tokens to query.
    /// @param amountIn Input size a live quote would price. Reserved; ignored by Swapper_v1.
    /// @return routeInfos Array of RouteInfo structs, one per target.
    function getRoutesFrom(
        address fromToken,
        address[] calldata targets,
        uint256 amountIn
    ) external view returns (RouteInfo[] memory routeInfos);

    /// @notice Query a single registry route (convenience for tooling and one-off swaps).
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @param amountIn Input size a live quote would price. Reserved; ignored by Swapper_v1.
    /// @return routeInfo Same shape as one element of `getRoutesFrom`.
    function getRoute(
        address fromToken,
        address toToken,
        uint256 amountIn
    ) external view returns (RouteInfo memory routeInfo);
}
