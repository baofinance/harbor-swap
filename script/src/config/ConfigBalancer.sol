// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Balancer V2 Vault deployment constants.
/// @dev The Balancer V2 Vault is a single singleton per chain deployed deterministically
///      at the same address on every supported network (Ethereum, Arbitrum, Optimism,
///      Polygon, Avalanche, Base, Gnosis, zkEVM, …). See
///      https://docs.balancer.fi/reference/contracts/deployment-addresses/mainnet.html and
///      the per-chain mirrors for the authoritative listing.
///
///      Balancer V3 introduces a new Vault at a different address; when we add a
///      `BalancerV3Swapper_v1` it will get its own config mixin. This file remains the
///      V2 reference for `BalancerSwapper_v1`.
abstract contract ConfigBalancer {
    /// @notice Balancer V2 Vault — same singleton address on every supported chain.
    address internal constant BALANCER_V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
}
