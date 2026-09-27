// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {Swapper_v1} from "@harbor-swap/Swapper_v1.sol";
import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";
import {CurveSwapper_v1} from "@harbor-swap/executors/CurveSwapper_v1.sol";
import {BalancerSwapper_v1} from "@harbor-swap/executors/BalancerSwapper_v1.sol";
import {VeloraSwapper_v1} from "@harbor-swap/aggregator/VeloraSwapper_v1.sol";
import {OneInchSwapper_v1} from "@harbor-swap/aggregator/OneInchSwapper_v1.sol";
import {FxSaveWstEthSwapper_v1} from "@harbor-swap/executors/FxSaveWstEthSwapper_v1.sol";
import {FxSaveWbtcSwapper_v1} from "@harbor-swap/executors/FxSaveWbtcSwapper_v1.sol";
import {FxSaveLbtcSwapper_v1} from "@harbor-swap/executors/FxSaveLbtcSwapper_v1.sol";
import {FxSaveEurcSwapper_v1} from "@harbor-swap/executors/FxSaveEurcSwapper_v1.sol";
import {WstEthWbtcSwapper_v1} from "@harbor-swap/executors/WstEthWbtcSwapper_v1.sol";
import {WstEthLbtcSwapper_v1} from "@harbor-swap/executors/WstEthLbtcSwapper_v1.sol";

import {ConfigVelora} from "@harbor-swap-script/config/ConfigVelora.sol";
import {ConfigOneInch} from "@harbor-swap-script/config/ConfigOneInch.sol";
import {ConfigBalancer} from "@harbor-swap-script/config/ConfigBalancer.sol";

/// @notice Harbor Swapper deployment logic.
/// @dev Swapper_v1 is a pure route registry shared across all HarborYield peg instances. Direct
///      executors (UniV3, Curve, Balancer) implement ISwapExecutor and are registered in
///      Swapper_v1 via setRoute(). Aggregator adapters (`VeloraSwapper_v1` primary, `OneInchSwapper_v1` optional) live
///      alongside the registry and are consumed directly by HarborYield_v1 via its role-gated
///      `redistribute` entrypoint (not through the Swapper_v1 registry). The keeper names which
///      adapter to use per call.
///      Salts: {saltPrefix}::swapper / {saltPrefix}::uniV3Swapper /
///      {saltPrefix}::curveSwapper / {saltPrefix}::balancerSwapper /
///      {saltPrefix}::veloraSwapper / {saltPrefix}::oneInchSwapper /
///      {saltPrefix}::fxSaveWstEthSwapper / {saltPrefix}::fxSaveWbtcSwapper /
///      {saltPrefix}::fxSaveLbtcSwapper / {saltPrefix}::fxSaveEurcSwapper /
///      {saltPrefix}::wstEthWbtcSwapper / {saltPrefix}::wstEthLbtcSwapper
///      (all shared, not peg-specific).
///
///      Deployment pattern:
///        deploySwapper(state)               — registry
///        deployUniV3Swapper(state)          — UniV3 executor (uses _uniV3RouterAddress())
///        deployFxSaveWstEthSwapper(state)   — fxSAVE ↔ wstETH composite (ETH mainnet route)
///        deployFxSaveWbtcSwapper(state)     — fxSAVE ↔ WBTC composite
///        deployFxSaveLbtcSwapper(state)     — fxSAVE ↔ LBTC composite (UniV3 wrap)
///        deployFxSaveEurcSwapper(state)     — fxSAVE → EURC composite (needs UniV3 router)
///        deployWstEthWbtcSwapper(state)     — wstETH → WBTC UniV3 multi-hop
///        deployWstEthLbtcSwapper(state)     — wstETH → LBTC UniV3 multi-hop
///        deployCurveSwapper(state)     — Curve executor (no canonical router; pool
///                                        addresses come from per-pair setRoute config)
///        deployBalancerSwapper(state)  — Balancer V2 executor (uses ConfigBalancer.VAULT)
///        deployVeloraSwapper(state)   — Velora Augustus v6.2 aggregator adapter (uses ConfigVelora)
///        deployOneInchSwapper(state)  — 1inch v6 aggregator adapter (uses ConfigOneInch)
///
///      Override _uniV3RouterAddress() in concrete deploy scripts and fork test setup
///      to supply the network-specific router. Unit tests that construct an ad-hoc mock
///      router/vault use the explicit-address overload: deployXxxSwapper(state, mockAddr).
abstract contract Swapper is Deployer, ConfigVelora, ConfigOneInch, ConfigBalancer {
    // this is duplicated from HarborDeployer
    address private constant TREASURY_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    function treasury() public view virtual override returns (address) {
        return TREASURY_OWNER;
    }

    function owner() public view virtual override returns (address) {
        return TREASURY_OWNER;
    }

    // ─── Swapper_v1 (route registry) ────────────────────────────────────────

    /// @notice Deploy Swapper_v1 implementation only.
    ///         Virtual so tests can inject a MockSwapper (no constructor args needed).
    function deploySwapperImplementation() internal virtual returns (address impl) {
        impl = address(new Swapper_v1());
    }

    function deploySwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        address impl = deploySwapperImplementation();
        _logDeploy("swapper", impl);

        _recordImplementation(stateData, "swapper", "@harbor-swap/Swapper_v1.sol", "Swapper_v1", impl);

        bytes memory initData = abi.encodeCall(Swapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "swapper", impl, initData);
    }

    // ─── UniV3Swapper_v1 (Uniswap v3 executor) ──────────────────────────────

    /// @notice Uniswap v3 SwapRouter address for the target network.
    ///         Must be overridden in every concrete deploy script and test contract.
    function _uniV3RouterAddress() internal virtual returns (address);

    /// @notice Deploy UniV3Swapper_v1 implementation only.
    ///         Virtual so tests can inject an alternative executor.
    function deployUniV3SwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new UniV3Swapper_v1(uniV3Router));
    }

    /// @notice Deploy UniV3Swapper using the router address from _uniV3RouterAddress().
    ///         Used by production scripts and fork test setup.
    function deployUniV3Swapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployUniV3SwapperWith(stateData, _uniV3RouterAddress());
    }

    /// @notice Deploy UniV3Swapper with an explicit router address.
    ///         Used by unit tests that construct an ad-hoc mock router.
    function deployUniV3Swapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployUniV3SwapperWith(stateData, uniV3Router);
    }

    function _deployUniV3SwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployUniV3SwapperImplementation(uniV3Router);
        _logDeploy("uniV3Swapper", impl);

        _recordImplementation(
            stateData,
            "uniV3Swapper",
            "@harbor-swap/executors/UniV3Swapper_v1.sol",
            "UniV3Swapper_v1",
            impl
        );

        bytes memory initData = abi.encodeCall(UniV3Swapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "uniV3Swapper", impl, initData);
    }

    // ─── CurveSwapper_v1 (Curve StableSwap-style executor) ─────────────────

    /// @notice Deploy CurveSwapper_v1 implementation only.
    ///         Virtual so tests can inject an alternative executor.
    function deployCurveSwapperImplementation() internal virtual returns (address impl) {
        impl = address(new CurveSwapper_v1());
    }

    /// @notice Deploy CurveSwapper. Curve has no canonical router across chains; pool
    ///         addresses are governance-configured per-pair via
    ///         `CurveSwapper_v1.setRoute(from, to, pool, kind, i, j, useUnderlying)` after
    ///         deployment (kind = the pool's Curve family, StableSwap vs Crypto).
    function deployCurveSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        address impl = deployCurveSwapperImplementation();
        _logDeploy("curveSwapper", impl);

        _recordImplementation(
            stateData,
            "curveSwapper",
            "@harbor-swap/executors/CurveSwapper_v1.sol",
            "CurveSwapper_v1",
            impl
        );

        bytes memory initData = abi.encodeCall(CurveSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "curveSwapper", impl, initData);
    }

    // ─── BalancerSwapper_v1 (Balancer V2 executor) ─────────────────────────

    /// @notice Deploy BalancerSwapper_v1 implementation only.
    ///         Virtual so tests can inject an alternative executor.
    function deployBalancerSwapperImplementation(address vault) internal virtual returns (address impl) {
        impl = address(new BalancerSwapper_v1(vault));
    }

    /// @notice Deploy BalancerSwapper using the canonical Balancer V2 Vault address from
    ///         ConfigBalancer. This is the production path on every supported chain.
    function deployBalancerSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployBalancerSwapperWith(stateData, BALANCER_V2_VAULT);
    }

    /// @notice Deploy BalancerSwapper with an explicit Vault address. Used by unit tests
    ///         that wire a MockBalancerVault.
    function deployBalancerSwapper(
        DeploymentTypes.State memory stateData,
        address vault
    ) internal returns (address proxy) {
        return _deployBalancerSwapperWith(stateData, vault);
    }

    function _deployBalancerSwapperWith(
        DeploymentTypes.State memory stateData,
        address vault
    ) private returns (address proxy) {
        address impl = deployBalancerSwapperImplementation(vault);
        _logDeploy("balancerSwapper", impl);

        _recordImplementation(
            stateData,
            "balancerSwapper",
            "@harbor-swap/executors/BalancerSwapper_v1.sol",
            "BalancerSwapper_v1",
            impl
        );

        bytes memory initData = abi.encodeCall(BalancerSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "balancerSwapper", impl, initData);
    }

    // ─── VeloraSwapper_v1 (Velora Augustus v6.2 aggregator adapter) ─────────

    /// @notice Deploy VeloraSwapper_v1 implementation only.
    ///         Virtual so tests can inject an alternative aggregator implementation.
    function deployVeloraSwapperImplementation(address veloraRouter) internal virtual returns (address impl) {
        impl = address(new VeloraSwapper_v1(veloraRouter));
    }

    /// @notice Deploy VeloraSwapper using the canonical Augustus v6.2 router address from
    ///         ConfigVelora. This is the production path on every supported chain.
    function deployVeloraSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployVeloraSwapperWith(stateData, VELORA_AUGUSTUS_V62);
    }

    /// @notice Deploy VeloraSwapper with an explicit router address. Used by unit tests
    ///         that wire a MockAugustusV62.
    function deployVeloraSwapper(
        DeploymentTypes.State memory stateData,
        address veloraRouter
    ) internal returns (address proxy) {
        return _deployVeloraSwapperWith(stateData, veloraRouter);
    }

    function _deployVeloraSwapperWith(
        DeploymentTypes.State memory stateData,
        address veloraRouter
    ) private returns (address proxy) {
        address impl = deployVeloraSwapperImplementation(veloraRouter);
        _logDeploy("veloraSwapper", impl);

        _recordImplementation(
            stateData,
            "veloraSwapper",
            "@harbor-swap/aggregator/VeloraSwapper_v1.sol",
            "VeloraSwapper_v1",
            impl
        );

        bytes memory initData = abi.encodeCall(VeloraSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "veloraSwapper", impl, initData);
    }

    // ─── OneInchSwapper_v1 (1inch v6 aggregator adapter) ───────────────────

    /// @notice Deploy OneInchSwapper_v1 implementation only.
    ///         Virtual so tests can inject an alternative aggregator implementation.
    function deployOneInchSwapperImplementation(address oneInchRouter) internal virtual returns (address impl) {
        impl = address(new OneInchSwapper_v1(oneInchRouter));
    }

    /// @notice Deploy OneInchSwapper using the canonical 1inch v6 router address from
    ///         ConfigOneInch. This is the production path on every supported chain.
    function deployOneInchSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployOneInchSwapperWith(stateData, ONE_INCH_AGGREGATION_ROUTER_V6);
    }

    /// @notice Deploy OneInchSwapper with an explicit router address. Used by unit tests
    ///         that wire a MockAggregationRouterV6.
    function deployOneInchSwapper(
        DeploymentTypes.State memory stateData,
        address oneInchRouter
    ) internal returns (address proxy) {
        return _deployOneInchSwapperWith(stateData, oneInchRouter);
    }

    function _deployOneInchSwapperWith(
        DeploymentTypes.State memory stateData,
        address oneInchRouter
    ) private returns (address proxy) {
        address impl = deployOneInchSwapperImplementation(oneInchRouter);
        _logDeploy("oneInchSwapper", impl);

        _recordImplementation(
            stateData,
            "oneInchSwapper",
            "@harbor-swap/aggregator/OneInchSwapper_v1.sol",
            "OneInchSwapper_v1",
            impl
        );

        bytes memory initData = abi.encodeCall(OneInchSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "oneInchSwapper", impl, initData);
    }

    // ─── FxSaveWstEthSwapper_v1 (fxSAVE ↔ wstETH composite route) ───────────

    /// @notice Deploy FxSaveWstEthSwapper_v1 implementation only.
    ///         Virtual so tests can inject a harness with mock pool/vault/router addresses.
    function deployFxSaveWstEthSwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new FxSaveWstEthSwapper_v1(uniV3Router));
    }

    /// @notice Deploy the fxSAVE ↔ wstETH composite executor for Ethereum mainnet.
    ///         Route constants are compiled into the implementation via
    ///         `ConfigFxSaveWstEthRoute_ETH_mainnet`. Needs the UniV3 router for the ETH stack hop.
    function deployFxSaveWstEthSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployFxSaveWstEthSwapperWith(stateData, _uniV3RouterAddress());
    }

    function deployFxSaveWstEthSwapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployFxSaveWstEthSwapperWith(stateData, uniV3Router);
    }

    function _deployFxSaveWstEthSwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployFxSaveWstEthSwapperImplementation(uniV3Router);
        _logDeploy("fxSaveWstEthSwapper", impl);

        _recordImplementation(
            stateData,
            "fxSaveWstEthSwapper",
            "@harbor-swap/executors/FxSaveWstEthSwapper_v1.sol",
            "FxSaveWstEthSwapper_v1",
            impl
        );

        bytes memory initData = abi.encodeCall(FxSaveWstEthSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "fxSaveWstEthSwapper", impl, initData);
    }

    // ─── FxSaveWbtcSwapper_v1 (fxSAVE ↔ WBTC) ───────────────────────────────

    function deployFxSaveWbtcSwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new FxSaveWbtcSwapper_v1(uniV3Router));
    }

    function deployFxSaveWbtcSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployFxSaveWbtcSwapperWith(stateData, _uniV3RouterAddress());
    }

    function deployFxSaveWbtcSwapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployFxSaveWbtcSwapperWith(stateData, uniV3Router);
    }

    function _deployFxSaveWbtcSwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployFxSaveWbtcSwapperImplementation(uniV3Router);
        _logDeploy("fxSaveWbtcSwapper", impl);
        _recordImplementation(
            stateData,
            "fxSaveWbtcSwapper",
            "@harbor-swap/executors/FxSaveWbtcSwapper_v1.sol",
            "FxSaveWbtcSwapper_v1",
            impl
        );
        bytes memory initData = abi.encodeCall(FxSaveWbtcSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "fxSaveWbtcSwapper", impl, initData);
    }

    // ─── FxSaveLbtcSwapper_v1 (fxSAVE ↔ LBTC) ───────────────────────────────

    function deployFxSaveLbtcSwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new FxSaveLbtcSwapper_v1(uniV3Router));
    }

    function deployFxSaveLbtcSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployFxSaveLbtcSwapperWith(stateData, _uniV3RouterAddress());
    }

    function deployFxSaveLbtcSwapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployFxSaveLbtcSwapperWith(stateData, uniV3Router);
    }

    function _deployFxSaveLbtcSwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployFxSaveLbtcSwapperImplementation(uniV3Router);
        _logDeploy("fxSaveLbtcSwapper", impl);
        _recordImplementation(
            stateData,
            "fxSaveLbtcSwapper",
            "@harbor-swap/executors/FxSaveLbtcSwapper_v1.sol",
            "FxSaveLbtcSwapper_v1",
            impl
        );
        bytes memory initData = abi.encodeCall(FxSaveLbtcSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "fxSaveLbtcSwapper", impl, initData);
    }

    // ─── FxSaveEurcSwapper_v1 (fxSAVE → EURC) ───────────────────────────────

    function deployFxSaveEurcSwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new FxSaveEurcSwapper_v1(uniV3Router));
    }

    function deployFxSaveEurcSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployFxSaveEurcSwapperWith(stateData, _uniV3RouterAddress());
    }

    function deployFxSaveEurcSwapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployFxSaveEurcSwapperWith(stateData, uniV3Router);
    }

    function _deployFxSaveEurcSwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployFxSaveEurcSwapperImplementation(uniV3Router);
        _logDeploy("fxSaveEurcSwapper", impl);
        _recordImplementation(
            stateData,
            "fxSaveEurcSwapper",
            "@harbor-swap/executors/FxSaveEurcSwapper_v1.sol",
            "FxSaveEurcSwapper_v1",
            impl
        );
        bytes memory initData = abi.encodeCall(FxSaveEurcSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "fxSaveEurcSwapper", impl, initData);
    }

    // ─── WstEthWbtcSwapper_v1 (wstETH → WBTC) ───────────────────────────────

    function deployWstEthWbtcSwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new WstEthWbtcSwapper_v1(uniV3Router));
    }

    function deployWstEthWbtcSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployWstEthWbtcSwapperWith(stateData, _uniV3RouterAddress());
    }

    function deployWstEthWbtcSwapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployWstEthWbtcSwapperWith(stateData, uniV3Router);
    }

    function _deployWstEthWbtcSwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployWstEthWbtcSwapperImplementation(uniV3Router);
        _logDeploy("wstEthWbtcSwapper", impl);
        _recordImplementation(
            stateData,
            "wstEthWbtcSwapper",
            "@harbor-swap/executors/WstEthWbtcSwapper_v1.sol",
            "WstEthWbtcSwapper_v1",
            impl
        );
        bytes memory initData = abi.encodeCall(WstEthWbtcSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "wstEthWbtcSwapper", impl, initData);
    }

    // ─── WstEthLbtcSwapper_v1 (wstETH → LBTC) ───────────────────────────────

    function deployWstEthLbtcSwapperImplementation(address uniV3Router) internal virtual returns (address impl) {
        impl = address(new WstEthLbtcSwapper_v1(uniV3Router));
    }

    function deployWstEthLbtcSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        return _deployWstEthLbtcSwapperWith(stateData, _uniV3RouterAddress());
    }

    function deployWstEthLbtcSwapper(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) internal returns (address proxy) {
        return _deployWstEthLbtcSwapperWith(stateData, uniV3Router);
    }

    function _deployWstEthLbtcSwapperWith(
        DeploymentTypes.State memory stateData,
        address uniV3Router
    ) private returns (address proxy) {
        address impl = deployWstEthLbtcSwapperImplementation(uniV3Router);
        _logDeploy("wstEthLbtcSwapper", impl);
        _recordImplementation(
            stateData,
            "wstEthLbtcSwapper",
            "@harbor-swap/executors/WstEthLbtcSwapper_v1.sol",
            "WstEthLbtcSwapper_v1",
            impl
        );
        bytes memory initData = abi.encodeCall(WstEthLbtcSwapper_v1.initialize, (address(this), owner()));
        proxy = _deployProxyAndRecord(stateData, "wstEthLbtcSwapper", impl, initData);
    }
}
