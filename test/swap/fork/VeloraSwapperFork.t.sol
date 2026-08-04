// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for VeloraSwapper_v1 against the real mainnet Augustus v6.2: that the router the
// deploy bakes in is the deployed contract, and that the two selectors the adapter allowlists
// are entrypoints Augustus actually dispatches rather than calldata a fallback would swallow.
//
// SCOPE — what these tests do NOT prove: no swap is executed here. Velora `routerData` is built
// by the Market API off-chain (`GET /prices` -> `POST /transactions/:chainId`) and cannot be
// produced inside a forge test, so the assumptions the unit mock encodes — that Augustus pulls
// the input with a plain ERC20 `transferFrom` against the adapter's approval, and that proceeds
// land on `msg.sender` when `beneficiary` is unset — remain unpinned. Closing that needs a
// captured API response committed as a fixture alongside the block it was quoted at.

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {VeloraV62Selectors} from "@harbor-swap/aggregator/VeloraV62Selectors.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract VeloraSwapperForkTest is ForkTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    address veloraSwapperProxy;
    string constant SALT_PREFIX = "fork_veloraswapper";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        // No router override: this is the production path, so the deploy resolves Augustus from
        // ConfigVelora exactly as a mainnet deploy would.
        deployVeloraSwapper(state);
        veloraSwapperProxy = _predictAddress("veloraSwapper");
    }

    /// @notice The production deploy bakes in the ConfigVelora address, and a contract is deployed
    ///         there on mainnet — the constructor's `ensureContract` would already have reverted
    ///         otherwise, so this pins the address itself rather than merely that one exists.
    function test_fork_router_isDeployedAugustusV62() public view {
        assertEq(IAggregatorSwapper(veloraSwapperProxy).ROUTER(), VELORA_AUGUSTUS_V62, "configured router");
        assertGt(VELORA_AUGUSTUS_V62.code.length, 0, "Augustus v6.2 is deployed at that address");
    }

    /// @notice Both allowlisted selectors are real Augustus entrypoints. A contract with a
    ///         permissive fallback accepts an unknown selector and returns empty success, so
    ///         "the call did not revert" proves nothing — the runtime bytecode is what
    ///         distinguishes an implemented entrypoint from one a fallback would swallow.
    function test_fork_augustus_implementsAllowlistedSelectors() public view {
        assertTrue(
            _implementsSelector(VELORA_AUGUSTUS_V62, VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN),
            "swapExactAmountIn is dispatched by the deployed Augustus"
        );
        assertTrue(
            _implementsSelector(VELORA_AUGUSTUS_V62, VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT),
            "swapExactAmountOut is dispatched by the deployed Augustus"
        );
    }

    /// @notice Augustus rejects calldata carrying an unknown selector rather than accepting it and
    ///         returning success. If this ever fails, the adapter's selector allowlist stops being
    ///         defence-in-depth and becomes the only thing standing between a mis-encoded keeper
    ///         call and a silent no-op that consumed the input.
    function test_fork_augustus_rejectsUnknownSelector() public {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = VELORA_AUGUSTUS_V62.call(abi.encodePacked(bytes4(0xdeadbeef)));
        assertFalse(ok, "unknown selector must revert, not be swallowed by a fallback");
    }
}
