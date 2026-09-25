// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ConfigWstEthWbtcRoute_ETH_mainnet
/// @notice Mainnet UniV3 multi-hop for wstETH → WBTC (hyBTC peg-equiv):
///           wstETH → WETH (0.01%) → WBTC (0.05%).
///         Reverse / remint via Velora.
// solhint-disable-next-line contract-name-capwords
library ConfigWstEthWbtcRoute_ETH_mainnet {
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    uint24 internal constant UNI_WSTETH_WETH_FEE = 100; // 0.01%
    uint24 internal constant UNI_WETH_WBTC_FEE = 500; // 0.05%

    function uniPath() internal pure returns (bytes memory) {
        return abi.encodePacked(WSTETH, UNI_WSTETH_WETH_FEE, WETH, UNI_WETH_WBTC_FEE, WBTC);
    }
}
