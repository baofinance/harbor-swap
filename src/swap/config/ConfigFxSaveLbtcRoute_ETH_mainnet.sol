// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";

/// @title ConfigFxSaveLbtcRoute_ETH_mainnet
/// @notice Mainnet route for fxSAVE ↔ LBTC:
///           fxSAVE → scrvUSD → redeem → crvUSD → USDC (Curve) → WBTC (Uni 0.05%)
///             → LBTC (Uni 0.01%)
///         and the reverse. Shares the USD→WBTC Uni hop with the WBTC composite.
// solhint-disable-next-line contract-name-capwords
library ConfigFxSaveLbtcRoute_ETH_mainnet {
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant SCRVUSD_VAULT = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;

    address internal constant POOL_FXSAVE_SCRVUSD = 0xb6E4821c6fCABe32f5F452dfD3Ef20Ce2A3a48E2;
    CurveExchangeLib.CurvePoolKind internal constant POOL_FXSAVE_SCRVUSD_KIND = CurveExchangeLib
        .CurvePoolKind
        .StableSwap;

    address internal constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    CurveExchangeLib.CurvePoolKind internal constant POOL_CRVUSD_USDC_KIND = CurveExchangeLib.CurvePoolKind.StableSwap;

    uint24 internal constant UNI_USDC_WBTC_FEE = 500; // 0.05%
    uint24 internal constant UNI_WBTC_LBTC_FEE = 100; // 0.01%

    int128 internal constant POOL2_I_FXSAVE = 0;
    int128 internal constant POOL2_J_SCRVUSD = 1;
    int128 internal constant POOL_USD_I_USDC = 0;
    int128 internal constant POOL_USD_J_CRVUSD = 1;
}
