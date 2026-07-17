// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title VeloraV62Selectors
/// @notice Allowed function selectors for Velora Augustus v6.2 calldata forwarded by
///         `VeloraSwapper_v1`. Harbor keepers must build `routerData` via the Velora Market
///         API (`GET /prices` → `POST /transactions/:chainId`) so the leading selector is one
///         of the canonical v6.2 swap entrypoints.
/// @dev Option A (minimal surface): only `swapExactAmountIn` and `swapExactAmountOut` on
///      Augustus v6.2 (`0x6a000f20005980200259b80c5102003040001068` on every supported chain).
///      See https://developers.velora.xyz/augustus-swapper/augustus-v6.2-smart-contracts
library VeloraV62Selectors {
    /// @notice `swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)`
    bytes4 internal constant SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;

    /// @notice `swapExactAmountOut(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)`
    bytes4 internal constant SWAP_EXACT_AMOUNT_OUT = 0x7f457675;
}
