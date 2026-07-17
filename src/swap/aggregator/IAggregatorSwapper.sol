// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IAggregatorSwapper
/// @notice Calldata-driven swap interface for off-chain-routed aggregator adapters.
///         Distinct from ISwapExecutor because the caller supplies opaque router calldata
///         per-swap (built off-chain by a keeper). The adapter targets one immutable router
///         (e.g. Velora Augustus v6.2) and is intended for low-urgency, governance-gated
///         rebalances that cannot be expressed as a stored direct-executor route.
/// @dev Output amount is verified by post-call balance delta against `minAmountOut`. Any
///      unspent `fromToken` is refunded to `msg.sender` (the adapter caller — not the router
///      and not the keeper's EOA). In HarborYield `redistribute`, `msg.sender` is HarborYield
///      itself; VaultManager then re-winds that refund into `fromVault` as vault shares,
///      so partial fills return to the source ERC4626 vault rather than stranding at HY or
///      paying the role holder.
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

    /// @notice `routerData` selector is not on the Harbor aggregator allowlist.
    error DisallowedRouterSelector(bytes4 selector);

    /// @notice Post-call output is below the slippage floor.
    error InsufficientAmountOut(uint256 amountOut, uint256 minAmountOut);

    /// @notice Aggregator swap entrypoint.
    ///         Pulls `amountIn` of `fromToken` from `msg.sender`, approves the immutable
    ///         router, calls `router.call(routerData)`, refunds any unspent `fromToken`
    ///         back to `msg.sender`, then delivers the `toToken` proceeds to `msg.sender`.
    ///         HarborYield `redistribute` is the primary caller: refunds land on HarborYield
    ///         and are re-deposited into `fromVault` by VaultManager (see harbor-yield).
    /// @param fromToken The token to swap from.
    /// @param toToken The token to swap to.
    /// @param amountIn The amount of `fromToken` to pull from `msg.sender`.
    /// @param minAmountOut Minimum acceptable proceeds in `toToken`; reverts if not met.
    /// @param routerData Opaque router calldata produced off-chain (keeper-built).
    /// @return amountOut Actual amount of `toToken` delivered to `msg.sender`.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) external returns (uint256 amountOut);

    /// @notice The immutable router this adapter calls (e.g. Velora Augustus v6.2).
    // solhint-disable-next-line func-name-mixedcase
    function ROUTER() external view returns (address);
}
