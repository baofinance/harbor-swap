// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {Swapper_v1} from "@harbor-swap/Swapper_v1.sol";
import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";
import {CurveSwapper_v1} from "@harbor-swap/executors/CurveSwapper_v1.sol";
import {BalancerSwapper_v1} from "@harbor-swap/executors/BalancerSwapper_v1.sol";
import {OneInchSwapper_v1} from "@harbor-swap/aggregator/OneInchSwapper_v1.sol";
import {FxSaveWstEthSwapper_v1} from "@harbor-swap/executors/FxSaveWstEthSwapper_v1.sol";

import {ConfigOneInch} from "@harbor-swap-script/config/ConfigOneInch.sol";
import {ConfigBalancer} from "@harbor-swap-script/config/ConfigBalancer.sol";

/// @notice Harbor Swapper deployment logic.
/// @dev Swapper_v1 is a pure route registry shared across all HY peg instances. Direct
///      executors (UniV3, Curve, Balancer) implement ISwapExecutor and are registered in
///      Swapper_v1 via setRoute(). The aggregator adapter (OneInchSwapper_v1) lives
///      alongside the registry and is consumed directly by HarborYield_v1 via its
///      role-gated executeAggregatorSwap entrypoint (not through the Swapper_v1 registry).
///      Salts: {saltPrefix}::swapper / {saltPrefix}::uniV3Swapper /
///      {saltPrefix}::curveSwapper / {saltPrefix}::balancerSwapper /
///      {saltPrefix}::oneInchSwapper / {saltPrefix}::fxSaveWstEthSwapper (all shared, not peg-specific).
///
///      Deployment pattern:
///        deploySwapper(state)               — registry
///        deployUniV3Swapper(state)          — UniV3 executor (uses _uniV3RouterAddress())
///        deployFxSaveWstEthSwapper(state)   — fxSAVE → wstETH composite (ETH mainnet route)
///        deployCurveSwapper(state)     — Curve executor (no canonical router; pool
///                                        addresses come from per-pair setRoute config)
///        deployBalancerSwapper(state)  — Balancer V2 executor (uses ConfigBalancer.VAULT)
///        deployOneInchSwapper(state)   — 1inch v6 aggregator adapter (uses ConfigOneInch)
///
///      Override _uniV3RouterAddress() in concrete deploy scripts and fork test setup
///      to supply the network-specific router. Unit tests that construct an ad-hoc mock
///      router/vault use the explicit-address overload: deployXxxSwapper(state, mockAddr).
abstract contract Swapper is HarborDeployer, ConfigOneInch, ConfigBalancer {
    // ─── Swapper_v1 (route registry) ────────────────────────────────────────

    /// @notice Deploy Swapper_v1 implementation only.
    ///         Virtual so tests can inject a MockSwapper (no constructor args needed).
    function deploySwapperImplementation() internal virtual returns (address impl) {
        impl = address(new Swapper_v1());
    }

    function deploySwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        console.log("    > swapper");

        address impl = deploySwapperImplementation();
        console.log("        Impl: %s", impl);

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
        console.log("    > uniV3Swapper");

        address impl = deployUniV3SwapperImplementation(uniV3Router);
        console.log("        Impl: %s", impl);

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
    ///         `CurveSwapper_v1.setRoute(from, to, pool, i, j, useUnderlying)` after
    ///         deployment.
    function deployCurveSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        console.log("    > curveSwapper");

        address impl = deployCurveSwapperImplementation();
        console.log("        Impl: %s", impl);

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
        console.log("    > balancerSwapper");

        address impl = deployBalancerSwapperImplementation(vault);
        console.log("        Impl: %s", impl);

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
    ///         that wire a MockAggregationRouterV6 (or future per-chain overrides if 1inch ever
    ///         publishes a different address).
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
        console.log("    > oneInchSwapper");

        address impl = deployOneInchSwapperImplementation(oneInchRouter);
        console.log("        Impl: %s", impl);

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

    // ─── FxSaveWstEthSwapper_v1 (fxSAVE → wstETH composite route) ───────────

    /// @notice Deploy FxSaveWstEthSwapper_v1 implementation only.
    ///         Virtual so tests can inject a harness with mock pool/vault addresses.
    function deployFxSaveWstEthSwapperImplementation() internal virtual returns (address impl) {
        impl = address(new FxSaveWstEthSwapper_v1());
    }

    /// @notice Deploy the fxSAVE → wstETH composite executor for Ethereum mainnet.
    ///         Route constants are compiled into the implementation via
    ///         `ConfigFxSaveWstEthRoute_ETH_mainnet`.
    function deployFxSaveWstEthSwapper(DeploymentTypes.State memory stateData) internal returns (address proxy) {
        console.log("    > fxSaveWstEthSwapper");

        address impl = deployFxSaveWstEthSwapperImplementation();
        console.log("        Impl: %s", impl);

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
}
