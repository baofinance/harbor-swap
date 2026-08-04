// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Swap-stack constants for Ethereum mainnet deploy scripts.
abstract contract ConfigSwap_ETH_mainnet {
    /// @notice fxSAVE token on Ethereum mainnet.
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice wstETH token on Ethereum mainnet.
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Mainnet Uniswap v3 SwapRouter.
    address internal constant UNIV3_ROUTER_MAINNET = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    /// @notice Expected route cost for fxSAVE → wstETH registry entry (1e18-scaled; 3e15 = 0.3%).
    uint256 internal constant FXSAVE_TO_WSTETH_ROUTE_COST_RATIO = 3e15;
    /// @notice Expected route cost for wstETH → fxSAVE registry entry (1e18-scaled; 3e15 = 0.3%).
    uint256 internal constant WSTETH_TO_FXSAVE_ROUTE_COST_RATIO = 3e15;
}
