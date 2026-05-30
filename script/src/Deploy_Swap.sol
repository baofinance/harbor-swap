// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploySwapStack} from "@harbor-swap-script/DeploySwapStack.sol";
import {ConfigSwap_ETH_mainnet} from "@harbor-swap-script/config/ConfigSwap_ETH_mainnet.sol";

/// @notice Abstract deploy class for the full Harbor swap stack (registry + all executors + 1inch).
/// @dev Lean concrete scripts inherit this and add `is Script` for forge broadcast context.
abstract contract Deploy_Swap is DeploySwapStack, ConfigSwap_ETH_mainnet {
    function _uniV3RouterAddress() internal pure override returns (address) {
        return UNIV3_ROUTER_MAINNET;
    }

    /// @notice Deploy registry + UniV3 + Curve + Balancer + 1inch via BaoFactory CREATE3.
    ///         Transfers proxy ownership to the Harbor multisig and persists deployment state.
    function deploySwapInfrastructure(string memory saltPrefix, string memory network) internal {
        _setSaltPrefix(saltPrefix);

        console.log("=== Deploying Swap Stack ===");
        console.log("  Salt:    %s", saltPrefix);
        console.log("  Network: %s", network);

        DeploymentTypes.State memory state = _shouldPersistState()
            ? DeploymentState.load(_stateFileRead())
            : _newSwapperState(saltPrefix, network);
        state.baoFactory = baoFactory();

        deploySwapStack(state, _fullSwapDeployOptions());
        deployFxSaveWstEthSwapper(state);

        flush("", "transfer swap ownership");
        _transferAllOwnerships();
        _saveState(state);
        _executeLocal();

        console.log("=== Swap Stack Deployment Done ===");
    }
}
