// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";

/// @title ConfigFxSaveWbtcRoute_ETH_mainnet
/// @notice Mainnet route for fxSAVE ↔ WBTC:
///           fxSAVE → scrvUSD → redeem → crvUSD → USDC (Curve StableSwap)
///             → WBTC (UniV3 0.05%)
///         and the reverse. Beats the thin Curve TwoCrypto crvUSD/WBTC hop at measured sizes.
// solhint-disable-next-line contract-name-capwords
library ConfigFxSaveWbtcRoute_ETH_mainnet {
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant SCRVUSD_VAULT = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;

    address internal constant POOL_FXSAVE_SCRVUSD = 0xb6E4821c6fCABe32f5F452dfD3Ef20Ce2A3a48E2;
    CurveExchangeLib.CurvePoolKind internal constant POOL_FXSAVE_SCRVUSD_KIND = CurveExchangeLib
        .CurvePoolKind
        .StableSwap;

    /// @notice Curve StableSwap crvUSD/USDC (coins: 0 = USDC, 1 = crvUSD).
    address internal constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    CurveExchangeLib.CurvePoolKind internal constant POOL_CRVUSD_USDC_KIND = CurveExchangeLib.CurvePoolKind.StableSwap;

    int128 internal constant POOL2_I_FXSAVE = 0;
    int128 internal constant POOL2_J_SCRVUSD = 1;
    int128 internal constant POOL_USD_I_USDC = 0;
    int128 internal constant POOL_USD_J_CRVUSD = 1;

    /// @notice UniV3 USDC/WBTC 0.05% (liquid vs direct 0.01% / Curve TwoCrypto).
    uint24 internal constant UNI_USDC_WBTC_FEE = 500;
}
