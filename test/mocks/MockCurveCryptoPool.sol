// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MockCurvePoolBase} from "@harbor-swap-test-mocks/MockCurvePoolBase.sol";

/// @notice Mock of the Curve crypto family (Tricrypto-style): `exchange` takes UINT256
///         indices and always returns dy. Crucially it does NOT implement the int128
///         `exchange` selector, and — like the real pools, whose Vyper `__default__` exists
///         to receive ETH — it ACCEPTS any unknown selector and returns empty success. A
///         mis-encoded (int128) call is therefore a SILENT NO-OP here, exactly as on
///         mainnet, which is the failure mode the executors' zero-output guard exists for.
contract MockCurveCryptoPool is MockCurvePoolBase {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        dy = _doSwap(coins[int128(int256(i))], coins[int128(int256(j))], dx, min_dy);
    }

    /// @dev Models the Vyper `__default__`: swallow any unknown selector, do nothing,
    ///      report success.
    // solhint-disable-next-line no-empty-blocks
    fallback() external payable {}

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}
