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

    // ---------------------------------------------------------------------------------------------
    // fxSAVE ↔ wstETH expected route cost.
    //
    // The registry stores ONE number per direction: the venue fee plus the slippage expected at a
    // typical trade size. It is size-independent, so the slippage term is a judgement about typical
    // size; the components below name where each part comes from rather than leaving a bare literal.
    //
    // Measured on mainnet at block 25,682,862 against the live pools. The composition is stated as a
    // sum: the terms compound multiplicatively, but below 1% the difference is under a basis point.
    //
    // Re-derive with `yarn measure:route-cost` (`yarn measure:route-cost 25682862` reproduces the
    // values below); `script/measure-route-cost.sh` explains what each term is measured against.
    // ---------------------------------------------------------------------------------------------

    /// @notice fxSAVE/scrvUSD StableSwap-NG pool fee — static, as read from the pool (2e6 of 1e10).
    uint256 internal constant FXSAVE_SCRVUSD_POOL_FEE = 2e14; // 0.020%

    /// @notice TricryptoLLAMA's expected fee. A Curve crypto pool recomputes its fee from pool
    ///         balances on every trade, so this is a distribution, not a constant: 30 samples evenly
    ///         spaced over 90 days gave min 0.059%, p25 0.319%, median 0.497%, mean 0.537%,
    ///         p75 0.723%, max 1.127%. The mean is used because this number feeds merit-order
    ///         RANKING, which wants an unbiased estimate rather than a conservative bound. This term
    ///         dominates the route's cost and no static value can track it — it is the strongest
    ///         argument for pricing the route from a live quote instead.
    uint256 internal constant TRICRYPTO_LLAMA_EXPECTED_FEE = 5.4e15; // 0.537%, rounded

    /// @notice Expected price impact per direction, measured at ~5% of the fxSAVE/scrvUSD pool's
    ///         shallow side (~72k fxSAVE), i.e. 3,600 fxSAVE in or the 1.73 wstETH that buys it.
    ///         The directions differ because the pool is fxSAVE-light (72k fxSAVE against 418k
    ///         scrvUSD): adding fxSAVE moves it toward balance and is cheap, taking fxSAVE out moves
    ///         it further away and costs about five times as much for the same value.
    uint256 internal constant FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE = 0.4e15; // 0.042% at 3,600 fxSAVE
    uint256 internal constant WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE = 2.4e15; // 0.241% at 1.73 wstETH

    /// @notice Expected route cost for the fxSAVE → wstETH registry entry (1e18-scaled). 0.60%.
    uint256 internal constant FXSAVE_TO_WSTETH_ROUTE_COST_RATIO =
        FXSAVE_SCRVUSD_POOL_FEE + TRICRYPTO_LLAMA_EXPECTED_FEE + FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE;

    /// @notice Expected route cost for the wstETH → fxSAVE registry entry (1e18-scaled). 0.80%.
    uint256 internal constant WSTETH_TO_FXSAVE_ROUTE_COST_RATIO =
        FXSAVE_SCRVUSD_POOL_FEE + TRICRYPTO_LLAMA_EXPECTED_FEE + WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE;
}
