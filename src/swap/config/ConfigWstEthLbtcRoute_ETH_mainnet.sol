// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ConfigWstEthLbtcRoute_ETH_mainnet
/// @notice Mainnet UniV3 multi-hop for wstETH → LBTC:
///           wstETH → WETH (0.01%) → WBTC (0.05%) → LBTC (0.01%).
// solhint-disable-next-line contract-name-capwords
library ConfigWstEthLbtcRoute_ETH_mainnet {
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;

    uint24 internal constant UNI_WSTETH_WETH_FEE = 100; // 0.01%
    uint24 internal constant UNI_WETH_WBTC_FEE = 500; // 0.05%
    uint24 internal constant UNI_WBTC_LBTC_FEE = 100; // 0.01%

    function uniPath() internal pure returns (bytes memory) {
        return abi.encodePacked(WSTETH, UNI_WSTETH_WETH_FEE, WETH, UNI_WETH_WBTC_FEE, WBTC, UNI_WBTC_LBTC_FEE, LBTC);
    }
}
