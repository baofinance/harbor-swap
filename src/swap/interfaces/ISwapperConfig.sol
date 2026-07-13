// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapperConfig
/// @notice Admin-facing interface for configuring swap routes in the Swapper dispatcher.
///         Consumed by governance and deploy scripts; not called by HarborYield at runtime.
interface ISwapperConfig {
    /// @notice Emitted when a registry route is created, updated, or cleared.
    /// @param swapExecutor `address(0)` when the route is removed.
    event RouteUpdated(
        address indexed fromToken,
        address indexed toToken,
        address indexed swapExecutor,
        uint256 feeRatio
    );

    /// @notice Configure the swap executor and fee for a token pair.
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @param swapExecutor Address of the ISwapExecutor implementation (e.g. UniV3Swapper_v1).
    ///                     Pass address(0) to remove a route.
    /// @param feeRatio Effective swap fee as a 1e18-scaled ratio (e.g. 3e15 = 0.3%).
    function setRoute(address fromToken, address toToken, address swapExecutor, uint256 feeRatio) external;
}
