// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title CurveExchangeLib
/// @notice Single home for encoding and executing Curve `exchange` calls across the two Curve
///         pool families. Used by every executor that talks to a Curve pool so the encoding
///         is never duplicated.
/// @dev Curve maintains two pool families with DIFFERENT index types in their `exchange`
///      signatures:
///        - StableSwap (legacy + NG): `exchange(int128,int128,uint256,uint256)`
///        - crypto (Tricrypto-style): `exchange(uint256,uint256,uint256,uint256)`
///      A crypto pool does NOT implement the int128 selector — and, worse, its Vyper
///      `__default__` (present to receive ETH) ACCEPTS any unknown selector and returns empty
///      success, so a mis-encoded call is a SILENT NO-OP, not a revert. The pool family is
///      therefore explicit, governance-declared route data, never inferred at call time.
///
///      The call is low-level for a second, independent reason: legacy StableSwap pools
///      declare `exchange` as void while newer ones return `uint256`. A low-level call is
///      agnostic to both; callers recover the output via post-call balance delta.
library CurveExchangeLib {
    /// @notice Which Curve pool family the pool belongs to — decides the `exchange` ABI.
    enum CurvePoolKind {
        StableSwap, // exchange(int128,int128,uint256,uint256)
        Crypto // exchange(uint256,uint256,uint256,uint256)
    }

    /// @notice The pool call itself failed (reverted); carries the pool's revert data.
    error PoolCallFailed(bytes revertData);

    /// @notice Execute `exchange` (or `exchange_underlying`) on `pool` with the ABI matching
    ///         its declared family. Reverts `PoolCallFailed` if the pool reverts. Output is
    ///         NOT returned — callers measure it via balance delta (void-return agnosticism).
    /// @param pool Curve pool to call.
    /// @param kind The pool's family (decides int128 vs uint256 index encoding).
    /// @param useUnderlying Call `exchange_underlying` instead of `exchange`.
    /// @param i Index of the input coin in the pool.
    /// @param j Index of the output coin in the pool.
    /// @param dx Amount of input coin to swap.
    /// @param minDy Pool-enforced minimum output (callers additionally enforce their own
    ///        balance-delta floor after the call).
    function exchange(
        address pool,
        CurvePoolKind kind,
        bool useUnderlying,
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minDy
    ) internal {
        bytes memory callData;
        if (kind == CurvePoolKind.StableSwap) {
            callData =
                useUnderlying
                    ? abi.encodeWithSignature("exchange_underlying(int128,int128,uint256,uint256)", i, j, dx, minDy)
                    : abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", i, j, dx, minDy);
        } else {
            callData =
                useUnderlying
                    ? abi.encodeWithSignature(
                        "exchange_underlying(uint256,uint256,uint256,uint256)",
                        uint256(int256(i)),
                        uint256(int256(j)),
                        dx,
                        minDy
                    )
                    : abi.encodeWithSignature(
                        "exchange(uint256,uint256,uint256,uint256)",
                        uint256(int256(i)),
                        uint256(int256(j)),
                        dx,
                        minDy
                    );
        }
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory revertData) = pool.call(callData); // solhint-disable-line avoid-low-level-calls
        if (!ok) {
            revert PoolCallFailed(revertData);
        }
    }
}
