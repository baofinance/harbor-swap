// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MockCurvePoolBase} from "@harbor-swap-test-mocks/MockCurvePoolBase.sol";

/// @notice Mock of the Curve StableSwap family (legacy + NG): `exchange` and
///         `exchange_underlying` take INT128 indices. Deliberately has NO fallback — a real
///         StableSwap pool reverts (empty) on an unknown selector, so a uint256-encoded
///         crypto-family call must revert here too, not be silently absorbed.
contract MockCurveStableSwapPool is MockCurvePoolBase {
    /// @notice underlying[i] is the token at index `i` when the caller uses
    ///         `exchange_underlying` (lending / meta pool wrap).
    mapping(int128 => address) public underlying;

    /// @notice Legacy 3pool-style behaviour: `exchange` declared void (returns no data).
    bool public returnVoid;

    function setUnderlying(int128 idx, address token) external {
        underlying[idx] = token;
    }

    function setReturnVoid(bool returnVoid_) external {
        returnVoid = returnVoid_;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        dy = _doSwap(coins[i], coins[j], dx, min_dy);
        if (returnVoid) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                return(0, 0)
            }
        }
    }

    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        dy = _doSwap(underlying[i], underlying[j], dx, min_dy);
        if (returnVoid) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                return(0, 0)
            }
        }
    }
}
