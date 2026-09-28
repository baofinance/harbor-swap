// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Velora Augustus v6.2 deployment constants.
/// @dev Mix into any HarborYield deploy class that wires an aggregator swap adapter.
///      Augustus v6.2 is deployed at the same address on every Velora-supported chain.
///      See https://developers.velora.xyz/augustus-swapper/augustus-v6.2-smart-contracts
///
///      Keeper calldata: Harbor Option A allowlist — only `VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN`
///      and `VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT`. Build via Velora Market API
///      (`GET /prices` → `POST /transactions/:chainId`); do not use direct-pool entrypoints
///      (`swapExactAmountInOnUniswapV2`, RFQ fills, etc.) unless the allowlist is expanded.
abstract contract ConfigVelora {
    /// @notice Velora Augustus v6.2 — same address on every supported Velora chain.
    address internal constant VELORA_AUGUSTUS_V62 = 0x6A000F20005980200259B80c5102003040001068;
}
