// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {ISwapper} from "@harbor-swap/interfaces/ISwapper.sol";
import {ISwapperConfig} from "@harbor-swap/interfaces/ISwapperConfig.sol";

/// @title Swapper_v1
/// @notice Swap route dispatcher. Pure registry: maps (from, to) → {swapExecutor, routeCostRatio}.
///         HarborYield batch-queries getRoutesFrom() once per compound() pass, then calls each
///         swapExecutor directly — no routing logic here. DEX-specific logic lives in
///         executor contracts (e.g. UniV3Swapper_v1) that implement ISwapExecutor.
///         `amountIn` is reserved for a future on-chain quote: v1 ignores it and leaves
///         `quoted = false` / `amountOut = 0` on every route, so no caller may branch on `quoted`.
/// @dev Security properties:
///      - Swapper holds no funds and executes no swaps.
///      - swapExecutor addresses are owner-gated via setRoute.
///      See [`src/swap/README.md`](README.md) threat model.
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) ABI matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner), not entry init args
contract Swapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapper, ISwapperConfig, HarborOwnableRoles, Initializable, UUPSUpgradeable {
    /// @notice Role allowing an address to configure swap routes via setRoute.
    uint256 public constant ROUTE_SETTER_ROLE = _ROLE_0;

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.Swapper
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.Swapper")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _SWAPPER_STORAGE = 0x272d0e8b8411949680c3c3cd26d3fcd30f9f18db2f9ab8f9c733e81384432c00;

    struct SwapperStorage {
        /// @notice Swap executor address per token pair. address(0) = no route configured.
        mapping(address from => mapping(address to => address)) swapExecutors;
        /// @notice Expected route cost per pair as a 1e18-scaled ratio (1e18 = 100%).
        ///         Set atomically with swapExecutors via setRoute.
        mapping(address from => mapping(address to => uint256)) routeCostRatios;
    }

    function _getSwapperStorage() private pure returns (SwapperStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SWAPPER_STORAGE
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    function swapExecutors(address from, address to) external view returns (address) {
        return _getSwapperStorage().swapExecutors[from][to];
    }

    function routeCostRatios(address from, address to) external view returns (uint256) {
        return _getSwapperStorage().routeCostRatios[from][to];
    }

    /// @inheritdoc ISwapperConfig
    function setRoute(
        address fromToken,
        address toToken,
        address swapExecutor,
        uint256 routeCostRatio
    ) external override onlyOwnerOrRoles(ROUTE_SETTER_ROLE) {
        SwapperStorage storage $ = _getSwapperStorage();
        $.swapExecutors[fromToken][toToken] = swapExecutor;
        $.routeCostRatios[fromToken][toToken] = swapExecutor != address(0) ? routeCostRatio : 0;
        emit RouteUpdated(fromToken, toToken, swapExecutor, $.routeCostRatios[fromToken][toToken]);
    }

    /// @inheritdoc ISwapper
    function getRoute(
        address fromToken,
        address toToken,
        uint256 amountIn
    ) external view override returns (RouteInfo memory routeInfo) {
        routeInfo = _routeInfo(fromToken, toToken, amountIn);
    }

    /// @inheritdoc ISwapper
    function getRoutesFrom(
        address fromToken,
        address[] calldata targets,
        uint256 amountIn
    ) external view override returns (RouteInfo[] memory routeInfos) {
        routeInfos = new RouteInfo[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            routeInfos[i] = _routeInfo(fromToken, targets[i], amountIn);
        }
    }

    /// @dev Pure-registry fill: `quoted` is always false and `amountOut` always 0, so `amountIn` has
    ///      nothing to price and is unnamed. Both become live when an executor can quote its venue.
    function _routeInfo(
        address fromToken,
        address toToken,
        uint256 /* amountIn */
    ) private view returns (RouteInfo memory routeInfo) {
        SwapperStorage storage $ = _getSwapperStorage();
        address exec = $.swapExecutors[fromToken][toToken];
        routeInfo = RouteInfo({
            target: toToken,
            available: exec != address(0),
            amountOut: 0,
            quoted: false,
            routeCostRatio: exec != address(0) ? $.routeCostRatios[fromToken][toToken] : 0,
            swapExecutor: exec
        });
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
