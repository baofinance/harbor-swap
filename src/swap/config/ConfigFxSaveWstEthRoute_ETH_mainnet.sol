// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";

/// @title ConfigFxSaveWstEthRoute_ETH_mainnet
/// @notice Mainnet route constants for the fxSAVE ↔ wstETH composite swap used by
///         `FxSaveWstEthSwapper_v1`. Leaves Curve once in USD stables and finishes on UniV3:
///           fxSAVE → scrvUSD → redeem → crvUSD → USDC (Curve StableSwap)
///             → WETH (Uni 0.05%) → wstETH (Uni 0.01%)
///         Reverse: wstETH → WETH → USDC → crvUSD → scrvUSD deposit → fxSAVE.
/// @dev Pool coin indices / Uni fee tiers are re-verified against real mainnet state by
///      the fork conformance tests on every fork run (pinned block).
///      Update this file and upgrade `FxSaveWstEthSwapper_v1` to change the route.
// solhint-disable-next-line contract-name-capwords
library ConfigFxSaveWstEthRoute_ETH_mainnet {
    /// @notice fxSAVE (f(x) USD saving token).
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice Canonical Lido wstETH.
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Wrapped Ether (Uni mid-hop).
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Native USDC (Curve + Uni mid-hop).
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Curve crvUSD stablecoin.
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    /// @notice Curve Savings crvUSD vault (ERC4626). Pool coin(1) on fxSAVE/scrvUSD; share
    ///         token is the vault itself.
    address internal constant SCRVUSD_VAULT = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;

    /// @notice fxSAVE / scrvUSD StableSwap-NG pool.
    address internal constant POOL_FXSAVE_SCRVUSD = 0xb6E4821c6fCABe32f5F452dfD3Ef20Ce2A3a48E2;

    /// @notice fxSAVE/scrvUSD is a StableSwap-NG pool: `exchange` takes int128 indices.
    CurveExchangeLib.CurvePoolKind internal constant POOL_FXSAVE_SCRVUSD_KIND = CurveExchangeLib
        .CurvePoolKind
        .StableSwap;

    /// @notice Curve StableSwap crvUSD/USDC (coins: 0 = USDC, 1 = crvUSD).
    address internal constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    CurveExchangeLib.CurvePoolKind internal constant POOL_CRVUSD_USDC_KIND = CurveExchangeLib.CurvePoolKind.StableSwap;

    /// @notice fxSAVE/scrvUSD pool: coins(0) = fxSAVE, coins(1) = scrvUSD vault shares.
    int128 internal constant POOL2_I_FXSAVE = 0;
    int128 internal constant POOL2_J_SCRVUSD = 1;

    /// @notice crvUSD/USDC pool: coins(0) = USDC, coins(1) = crvUSD.
    int128 internal constant POOL_USD_I_USDC = 0;
    int128 internal constant POOL_USD_J_CRVUSD = 1;

    /// @notice UniV3 fee tiers on the ETH stack hop.
    uint24 internal constant UNI_USDC_WETH_FEE = 500; // 0.05%
    uint24 internal constant UNI_WETH_WSTETH_FEE = 100; // 0.01%

    /// @notice UniV3 multi-hop: USDC → WETH (0.05%) → wstETH (0.01%).
    function uniPathUsdcToWstEth() internal pure returns (bytes memory) {
        return abi.encodePacked(USDC, UNI_USDC_WETH_FEE, WETH, UNI_WETH_WSTETH_FEE, WSTETH);
    }

    /// @notice UniV3 multi-hop: wstETH → WETH (0.01%) → USDC (0.05%).
    function uniPathWstEthToUsdc() internal pure returns (bytes memory) {
        return abi.encodePacked(WSTETH, UNI_WETH_WSTETH_FEE, WETH, UNI_USDC_WETH_FEE, USDC);
    }
}
