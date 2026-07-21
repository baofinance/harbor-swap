// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";

/// @title ForkTestBase
/// @notice Shared setup for mainnet fork tests.
/// @dev The block is pinned so fork runs are deterministic, cacheable (foundry caches state
///      under ~/.foundry/cache) and exactly assertable — an unpinned `latest` fork makes
///      amounts unassertable and the suite flaky. Bumping the block is a deliberate,
///      reviewable change.
///
///      Requires `MAINNET_RPC_URL` (wired to the `mainnet` endpoint in foundry.toml).
abstract contract ForkTestBase is BaoTest {
    uint256 internal constant MAINNET_FORK_BLOCK = 25_500_000;

    function _forkMainnet() internal {
        vm.createSelectFork(vm.rpcUrl("mainnet"), MAINNET_FORK_BLOCK);
    }

    /// @dev True when `target` dispatches `selector` to a real function.
    ///      A contract with a permissive fallback (e.g. a Vyper `__default__`, as Curve crypto
    ///      pools have to receive ETH) ACCEPTS an unknown selector and returns empty success —
    ///      so "the call did not revert" proves nothing. Scanning the runtime bytecode for the
    ///      selector is what actually distinguishes "implemented" from "swallowed by fallback".
    function _implementsSelector(address target, bytes4 selector) internal view returns (bool) {
        bytes memory code = target.code;
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (
                code[i] == selector[0] &&
                code[i + 1] == selector[1] &&
                code[i + 2] == selector[2] &&
                code[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }
}
