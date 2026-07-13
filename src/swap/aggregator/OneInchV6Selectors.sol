// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title OneInchV6Selectors
/// @notice Allowed function selectors for 1inch Aggregation Router V6 calldata forwarded by
///         `OneInchSwapper_v1`. Harbor keepers must build `routerData` via the 1inch Swap API
///         (Pathfinder) so the leading selector is `SWAP`.
/// @dev Option A (minimal surface): only `swap(address executor, SwapDescription desc, bytes data)`.
///      Selector verified on mainnet router 0x111111125421cA6dc452d289314280a0f8842A65.
///      See https://help.1inch.io/en/articles/9168298-aggregation-router-v6
library OneInchV6Selectors {
    /// @notice `swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)`
    bytes4 internal constant SWAP = 0x07ed2379;
}
