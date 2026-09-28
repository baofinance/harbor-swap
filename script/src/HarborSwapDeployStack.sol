// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

/// @notice Shared swap-stack deployment helpers for standalone and HarborYield deploy scripts.
/// @dev Always deploys Swapper_v1 + UniV3Swapper_v1. Curve, Balancer, and aggregators are optional
///      via SwapDeployOptions. Velora is the primary aggregator; 1inch is an optional alternative.
abstract contract HarborSwapDeployStack is Swapper {
    struct SwapDeployOptions {
        bool deployCurve;
        bool deployBalancer;
        bool deployVelora;
        bool deployOneInch;
    }

    /// @notice Swap registry + UniV3 executor only (current default for HarborYield deploy).
    function _defaultSwapDeployOptions() internal pure returns (SwapDeployOptions memory opts) {}

    /// @notice Full direct-executor stack plus primary aggregator (Velora) and optional 1inch.
    function _fullSwapDeployOptions() internal pure returns (SwapDeployOptions memory opts) {
        opts = SwapDeployOptions({deployCurve: true, deployBalancer: true, deployVelora: true, deployOneInch: true});
    }

    /// @notice Registry + UniV3 + Velora only — primary aggregator path without 1inch.
    function _veloraAggregatorDeployOptions() internal pure returns (SwapDeployOptions memory opts) {
        opts = SwapDeployOptions({deployCurve: false, deployBalancer: false, deployVelora: true, deployOneInch: false});
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
        if (opts.deployVelora) {
            deployVeloraSwapper(state);
        }
        if (opts.deployOneInch) {
            deployOneInchSwapper(state);
        }
    }
}
