// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ConfigFxSaveWstEthRoute_ETH_mainnet
/// @notice Mainnet route constants for the fxSAVE ↔ wstETH composite swap used by
///         `FxSaveWstEthSwapper_v1`. Mirrors the Curve UI path:
///           wstETH → crvUSD (TricryptoLLAMA) → scrvUSD vault deposit → fxSAVE pool
///         Harbor `distribute()` uses the reverse: fxSAVE → scrvUSD shares → redeem → wstETH.
/// @dev Pool coin indices verified on-chain via `coins(uint256)` at deployment time.
///      Update this file and upgrade `FxSaveWstEthSwapper_v1` to change the route.
library ConfigFxSaveWstEthRoute_ETH_mainnet {
    /// @notice fxSAVE (f(x) USD saving token).
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice Canonical Lido wstETH.
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Curve crvUSD stablecoin.
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    /// @notice Curve Savings crvUSD vault (ERC4626). Pool coin(1) on fxSAVE/scrvUSD; share
    ///         token is the vault itself.
    address internal constant SCRVUSD_VAULT = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;

    /// @notice fxSAVE / scrvUSD StableSwap-NG pool.
    address internal constant POOL_FXSAVE_SCRVUSD = 0xb6E4821c6fCABe32f5F452dfD3Ef20Ce2A3a48E2;

    /// @notice TricryptoLLAMA pool (crvUSD / tBTC / wstETH).
    address internal constant POOL_TRICRYPTO_LLAMA = 0x2889302a794dA87fBF1D6Db415C1492194663D13;

    /// @notice fxSAVE/scrvUSD pool: coins(0) = fxSAVE, coins(1) = scrvUSD vault shares.
    int128 internal constant POOL2_I_FXSAVE = 0;
    int128 internal constant POOL2_J_SCRVUSD = 1;

    /// @notice TricryptoLLAMA: coins(0) = crvUSD, coins(1) = tBTC, coins(2) = wstETH.
    int128 internal constant POOL1_I_CRVUSD = 0;
    int128 internal constant POOL1_J_WSTETH = 2;
}
