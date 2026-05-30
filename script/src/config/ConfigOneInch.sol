// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice 1inch Aggregation Router V6 deployment constants.
/// @dev Mix into any HarborYield deploy class that wires an aggregator swap adapter.
///      The v6 router uses a deterministic CREATE2 deploy and lives at the same address
///      on all supported chains (Ethereum, Arbitrum, Optimism, Polygon, BSC, Avalanche,
///      Base, Gnosis, Fantom, zkSync Era, Linea, Scroll, Mantle, Celo, Aurora, …).
///      See https://help.1inch.io/en/articles/9168298-aggregation-router-v6 for the
///      authoritative list. If 1inch ever publishes a different address for a chain we
///      target, override `_oneInchRouterAddress()` in the chain-specific deployer.
abstract contract ConfigOneInch {
    /// @notice 1inch Aggregation Router V6 — deterministic CREATE2 address on all major chains.
    address internal constant ONE_INCH_AGGREGATION_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;
}
