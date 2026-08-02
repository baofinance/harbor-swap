// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IAggregatorSwapper
/// @notice Calldata-driven swap interface for off-chain-routed aggregator adapters.
///         Distinct from ISwapExecutor because the caller supplies opaque router calldata
///         per-swap (built off-chain by a keeper). The adapter targets one immutable router
///         (e.g. 1inch v6) and is intended for low-urgency, governance-gated rebalances
///         that cannot be expressed as a stored direct-executor route.
/// @dev Output amount is verified by post-call balance delta against `minAmountOut`. Any
///      unspent `fromToken` (1inch v6 `_PARTIAL_FILL` flag) is refunded to `msg.sender`.
interface IAggregatorSwapper {
    /// @notice Emitted on every successful swap.
    event AggregatorSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 refundedIn
    );

    /// @notice The underlying router call reverted; the original revert data is forwarded.
    error RouterCallFailed(bytes revertData);

    /// @notice `routerData` is shorter than four bytes (no function selector).
    error RouterCalldataTooShort();

    /// @notice `routerData` selector is not on the Harbor 1inch v6 allowlist.
    error DisallowedRouterSelector(bytes4 selector);

    /// @notice Aggregator swap entrypoint.
    ///         Pulls `amountIn` of `fromToken` from `msg.sender`, approves the immutable
    ///         router, calls `router.call(routerData)`, refunds any unspent `fromToken`
    ///         back to `msg.sender`, then delivers the `toToken` proceeds to `msg.sender`.
    /// @param fromToken The token to swap from.
    /// @param toToken The token to swap to.
    /// @param amountIn The amount of `fromToken` to pull from `msg.sender`.
    /// @param minAmountOutPerUnitIn Minimum acceptable RATE: `toToken` units per 1e18 units of
    ///        `fromToken` SPENT; reverts if not met. A rate rather than a total because this adapter
    ///        refunds unspent input — partial fills are its normal case, and an absolute floor would
    ///        either reject an honest one or, if scaled down by the fill, admit a sliver at any price.
    ///        Token decimals are the caller's to fold in. 0 disables the floor, which is what a caller
    ///        enforcing its own end-to-end value bound passes.
    /// @param routerData Opaque router calldata produced off-chain (keeper-built).
    /// @return amountOut Actual amount of `toToken` delivered to `msg.sender`.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOutPerUnitIn,
        bytes calldata routerData
    ) external returns (uint256 amountOut);

    /// @notice The immutable router this adapter calls (e.g. 1inch AggregationRouterV6).
    // solhint-disable-next-line func-name-mixedcase
    function ROUTER() external view returns (address);
}
