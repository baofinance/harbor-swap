// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {HarborSwapDeployStack} from "@harbor-swap-script/HarborSwapDeployStack.sol";
import {ConfigSwap_ETH_mainnet} from "@harbor-swap-script/config/ConfigSwap_ETH_mainnet.sol";
import {ISwapperConfig} from "@harbor-swap/interfaces/ISwapperConfig.sol";
import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";

/// @notice Abstract deploy class for the full Harbor swap stack (registry + all executors + aggregators).
/// @dev Lean concrete scripts inherit this and add `is Script` for forge broadcast context.
abstract contract Deploy_Swap is HarborSwapDeployStack, ConfigSwap_ETH_mainnet {
    function _uniV3RouterAddress() internal pure override returns (address) {
        return UNIV3_ROUTER_MAINNET;
    }

    /// @notice Deploy registry + UniV3 + Curve + Balancer + Velora + 1inch via BaoFactory CREATE3.
    ///         Transfers proxy ownership to the Harbor multisig and persists deployment state.
    function deploySwapInfrastructure(string memory saltPrefix, string memory network) internal {
        _setSaltPrefix(saltPrefix);

        console.log("=== Deploying Swap Stack ===");
        console.log("  Salt:    %s", saltPrefix);
        console.log("  Network: %s", network);

        DeploymentTypes.State memory state =
            _shouldPersistState() ? DeploymentState.load(_stateFileRead()) : DeploymentState.fresh(saltPrefix, network);
        state.baoFactory = baoFactory();

        deploySwapStack(state, _fullSwapDeployOptions());
        deployHyPegEquivExecutors(state);
        configureHyPegEquivRoutes();

        flush("", "transfer swap ownership");
        _transferAllOwnerships();
        _saveState(state);
        _executeQueued();

        console.log("=== Swap Stack Deployment Done ===");
    }

    /// @notice Deploy all hy peg-equiv composite executors (fxSAVE/wstETH/BTC/EURC paths).
    function deployHyPegEquivExecutors(DeploymentTypes.State memory state) internal {
        deployFxSaveWstEthSwapper(state);
        deployFxSaveWbtcSwapper(state);
        deployFxSaveLbtcSwapper(state);
        deployFxSaveEurcSwapper(state);
        deployWstEthWbtcSwapper(state);
        deployWstEthLbtcSwapper(state);
    }

    /// @notice Register hy peg-equiv routes in `Swapper_v1` while the deploy script still owns it.
    function configureHyPegEquivRoutes() internal {
        configureFxSaveWstEthRoutes();
        configureFxSaveWbtcRoutes();
        configureFxSaveLbtcRoutes();
        configureFxSaveEurcRoutes();
        configureWstEthWbtcRoutes();
        configureWstEthLbtcRoutes();
        configureWstEthEurcRoutes();
    }

    /// @notice Register fxSAVE ↔ wstETH in `Swapper_v1` (Layer 2 only; venues are in the executor impl).
    function configureFxSaveWstEthRoutes() internal {
        address swapper = _predictAddress("swapper");
        address fxSaveWstEth = _predictAddress("fxSaveWstEthSwapper");

        console.log("--- Configuring fxSAVE <-> wstETH registry routes ---");
        console.log("  Swapper:           %s", swapper);
        console.log("  FxSaveWstEth exec: %s", fxSaveWstEth);

        ISwapperConfig(swapper).setRoute(FXSAVE, WSTETH, fxSaveWstEth, FXSAVE_TO_WSTETH_ROUTE_COST_RATIO);
        ISwapperConfig(swapper).setRoute(WSTETH, FXSAVE, fxSaveWstEth, WSTETH_TO_FXSAVE_ROUTE_COST_RATIO);
    }

    function configureFxSaveWbtcRoutes() internal {
        address swapper = _predictAddress("swapper");
        address exec = _predictAddress("fxSaveWbtcSwapper");
        console.log("--- Configuring fxSAVE <-> WBTC registry routes ---");
        ISwapperConfig(swapper).setRoute(FXSAVE, WBTC, exec, FXSAVE_TO_WBTC_ROUTE_COST_RATIO);
        ISwapperConfig(swapper).setRoute(WBTC, FXSAVE, exec, WBTC_TO_FXSAVE_ROUTE_COST_RATIO);
    }

    function configureFxSaveLbtcRoutes() internal {
        address swapper = _predictAddress("swapper");
        address exec = _predictAddress("fxSaveLbtcSwapper");
        console.log("--- Configuring fxSAVE <-> LBTC registry routes ---");
        ISwapperConfig(swapper).setRoute(FXSAVE, LBTC, exec, FXSAVE_TO_LBTC_ROUTE_COST_RATIO);
        ISwapperConfig(swapper).setRoute(LBTC, FXSAVE, exec, LBTC_TO_FXSAVE_ROUTE_COST_RATIO);
    }

    function configureFxSaveEurcRoutes() internal {
        address swapper = _predictAddress("swapper");
        address exec = _predictAddress("fxSaveEurcSwapper");
        console.log("--- Configuring fxSAVE -> EURC registry route ---");
        ISwapperConfig(swapper).setRoute(FXSAVE, EURC, exec, FXSAVE_TO_EURC_ROUTE_COST_RATIO);
    }

    function configureWstEthWbtcRoutes() internal {
        address swapper = _predictAddress("swapper");
        address exec = _predictAddress("wstEthWbtcSwapper");
        console.log("--- Configuring wstETH -> WBTC registry route ---");
        ISwapperConfig(swapper).setRoute(WSTETH, WBTC, exec, WSTETH_TO_WBTC_ROUTE_COST_RATIO);
    }

    function configureWstEthLbtcRoutes() internal {
        address swapper = _predictAddress("swapper");
        address exec = _predictAddress("wstEthLbtcSwapper");
        console.log("--- Configuring wstETH -> LBTC registry route ---");
        ISwapperConfig(swapper).setRoute(WSTETH, LBTC, exec, WSTETH_TO_LBTC_ROUTE_COST_RATIO);
    }

    /// @notice Layer 1 UniV3 path + Layer 2 registry for wstETH → EURC (multi-hop via USDC).
    function configureWstEthEurcRoutes() internal {
        address swapper = _predictAddress("swapper");
        address uniV3 = _predictAddress("uniV3Swapper");
        console.log("--- Configuring wstETH -> EURC (UniV3 multi-hop) ---");
        UniV3Swapper_v1(uniV3).setPath(WSTETH, EURC, _wstEthToEurcUniPath());
        ISwapperConfig(swapper).setRoute(WSTETH, EURC, uniV3, WSTETH_TO_EURC_ROUTE_COST_RATIO);
    }
}
