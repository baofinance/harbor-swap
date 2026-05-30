// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

/// @notice Shared swap-stack deployment helpers for standalone and HarborYield deploy scripts.
/// @dev Always deploys Swapper_v1 + UniV3Swapper_v1. Curve, Balancer, and 1inch are optional
///      via SwapDeployOptions.
abstract contract DeploySwapStack is Swapper {
    struct SwapDeployOptions {
        bool deployCurve;
        bool deployBalancer;
        bool deployOneInch;
    }

    /// @notice Swap registry + UniV3 executor only (current default for HarborYield deploy).
    function _defaultSwapDeployOptions() internal pure returns (SwapDeployOptions memory opts) {}

    /// @notice Full direct-executor stack plus 1inch aggregator adapter.
    function _fullSwapDeployOptions() internal pure returns (SwapDeployOptions memory opts) {
        opts = SwapDeployOptions({deployCurve: true, deployBalancer: true, deployOneInch: true});
    }

    function _newSwapperState(
        string memory saltPrefix,
        string memory network
    ) internal view returns (DeploymentTypes.State memory state) {
        state = DeploymentTypes.State({
            network: network,
            saltPrefix: saltPrefix,
            directoryPrefix: "",
            implementations: new DeploymentTypes.ImplementationRecord[](0),
            proxies: new DeploymentTypes.ProxyRecord[](0),
            baoFactory: baoFactory()
        });
    }

    /// @notice Deploy swap infrastructure according to opts. Caller must have set salt prefix.
    function deploySwapStack(DeploymentTypes.State memory state, SwapDeployOptions memory opts) internal {
        console.log("--- Deploying Swap Stack ---");
        deploySwapper(state);
        deployUniV3Swapper(state);
        if (opts.deployCurve) {
            deployCurveSwapper(state);
        }
        if (opts.deployBalancer) {
            deployBalancerSwapper(state);
        }
        if (opts.deployOneInch) {
            deployOneInchSwapper(state);
        }
    }
}
