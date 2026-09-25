// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Swap-stack constants for Ethereum mainnet deploy scripts.
abstract contract ConfigSwap_ETH_mainnet {
    /// @notice fxSAVE token on Ethereum mainnet.
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice wstETH token on Ethereum mainnet.
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice WBTC on Ethereum mainnet.
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @notice Lombard LBTC on Ethereum mainnet.
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;

    /// @notice Circle EURC on Ethereum mainnet.
    address internal constant EURC = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;

    /// @notice Native USDC on Ethereum mainnet.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Mainnet Uniswap v3 SwapRouter.
    address internal constant UNIV3_ROUTER_MAINNET = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // ---------------------------------------------------------------------------------------------
    // fxSAVE ↔ wstETH expected route cost (measured — see yarn measure:route-cost:eth).
    // Legs: StableSwap fees + Uni USDC/WETH 0.05% + WETH/wstETH 0.01% + size impact.
    // ---------------------------------------------------------------------------------------------

    /// @notice fxSAVE/scrvUSD StableSwap-NG pool fee — static, as read from the pool (2e6 of 1e10).
    uint256 internal constant FXSAVE_SCRVUSD_POOL_FEE = 2e14; // 0.020%

    /// @notice Curve crvUSD/USDC StableSwap fee (provisional; confirm via measure:route-cost:eth).
    uint256 internal constant CRVUSD_USDC_POOL_FEE = 1e14; // 0.01%

    uint256 internal constant UNI_USDC_WETH_FEE = 5e14; // 0.05%
    uint256 internal constant UNI_WETH_WSTETH_FEE = 1e14; // 0.01%

    /// @notice Size impact at ~5% of fxSAVE/scrvUSD shallow side (measured — see measure:route-cost:eth).
    ///         Forward can print slightly negative vs epsilon at small sizes; floor at 0 for ranking.
    uint256 internal constant FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE = 0; // ~0 at 3.8k fxSAVE basis
    uint256 internal constant WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE = 0.6e15; // 0.06% at ~1.29 wstETH

    /// @notice Expected route cost for the fxSAVE → wstETH registry entry (1e18-scaled). ~0.09%.
    uint256 internal constant FXSAVE_TO_WSTETH_ROUTE_COST_RATIO =
        FXSAVE_SCRVUSD_POOL_FEE +
            CRVUSD_USDC_POOL_FEE +
            UNI_USDC_WETH_FEE +
            UNI_WETH_WSTETH_FEE +
            FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE;

    /// @notice Expected route cost for the wstETH → fxSAVE registry entry (1e18-scaled). ~0.15%.
    uint256 internal constant WSTETH_TO_FXSAVE_ROUTE_COST_RATIO =
        FXSAVE_SCRVUSD_POOL_FEE +
            CRVUSD_USDC_POOL_FEE +
            UNI_USDC_WETH_FEE +
            UNI_WETH_WSTETH_FEE +
            WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE;

    // ---------------------------------------------------------------------------------------------
    // hyBTC / hyUSD BTC-wrapper routes — refreshed via yarn measure:route-cost:btc.
    // fxSAVE→BTC: Curve TwoCrypto ~1% + Uni wrap 0.01% + size impact.
    // wstETH→BTC: UniV3 wstETH/WETH 0.01% + WETH/WBTC 0.05% (+ LBTC wrap 0.01%).
    // ---------------------------------------------------------------------------------------------

    uint256 internal constant CRVUSD_WBTC_EXPECTED_FEE = 1e16; // ~1%
    uint256 internal constant UNI_WBTC_LBTC_FEE = 1e14; // 0.01%
    uint256 internal constant BTC_ROUTE_EXPECTED_SLIPPAGE = 3e15; // 0.3% at 15k fxSAVE

    uint256 internal constant FXSAVE_TO_WBTC_ROUTE_COST_RATIO =
        FXSAVE_SCRVUSD_POOL_FEE + CRVUSD_WBTC_EXPECTED_FEE + BTC_ROUTE_EXPECTED_SLIPPAGE;
    uint256 internal constant WBTC_TO_FXSAVE_ROUTE_COST_RATIO = FXSAVE_TO_WBTC_ROUTE_COST_RATIO;

    uint256 internal constant FXSAVE_TO_LBTC_ROUTE_COST_RATIO = FXSAVE_TO_WBTC_ROUTE_COST_RATIO + UNI_WBTC_LBTC_FEE;
    uint256 internal constant LBTC_TO_FXSAVE_ROUTE_COST_RATIO = FXSAVE_TO_LBTC_ROUTE_COST_RATIO;

    uint256 internal constant UNI_WSTETH_WETH_FEE = 1e14; // 0.01%
    uint256 internal constant UNI_WETH_WBTC_FEE = 5e14; // 0.05%
    uint256 internal constant WSTETH_BTC_ROUTE_EXPECTED_SLIPPAGE = 0; // flat at 10 wstETH

    uint256 internal constant WSTETH_TO_WBTC_ROUTE_COST_RATIO =
        UNI_WSTETH_WETH_FEE + UNI_WETH_WBTC_FEE + WSTETH_BTC_ROUTE_EXPECTED_SLIPPAGE;
    uint256 internal constant WSTETH_TO_LBTC_ROUTE_COST_RATIO = WSTETH_TO_WBTC_ROUTE_COST_RATIO + UNI_WBTC_LBTC_FEE;

    // ---------------------------------------------------------------------------------------------
    // hyEUR routes — refreshed via yarn measure:route-cost:eur for fxSAVE→EURC.
    // wstETH→EURC Uni path is thin at small epsilon; keep a conservative provisional impact.
    // ---------------------------------------------------------------------------------------------

    uint256 internal constant UNI_USDC_EURC_FEE = 5e14; // 0.05%
    uint256 internal constant EUR_ROUTE_EXPECTED_SLIPPAGE = 1.6e15; // 0.16% at 15k fxSAVE

    uint256 internal constant FXSAVE_TO_EURC_ROUTE_COST_RATIO =
        FXSAVE_SCRVUSD_POOL_FEE + CRVUSD_USDC_POOL_FEE + UNI_USDC_EURC_FEE + EUR_ROUTE_EXPECTED_SLIPPAGE;

    uint256 internal constant UNI_WSTETH_USDC_FEE = 5e14; // 0.05%
    uint256 internal constant WSTETH_EUR_ROUTE_EXPECTED_SLIPPAGE = 5e15; // 0.5% provisional (thin vs epsilon)
    uint256 internal constant WSTETH_TO_EURC_ROUTE_COST_RATIO =
        UNI_WSTETH_USDC_FEE + UNI_USDC_EURC_FEE + WSTETH_EUR_ROUTE_EXPECTED_SLIPPAGE;

    /// @notice UniV3 multi-hop path bytes for wstETH → USDC (0.05%) → EURC (0.05%).
    function _wstEthToEurcUniPath() internal pure returns (bytes memory) {
        return abi.encodePacked(WSTETH, uint24(500), USDC, uint24(500), EURC);
    }
}
