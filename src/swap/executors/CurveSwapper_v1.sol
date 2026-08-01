// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {Token} from "@bao/Token.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";

/// @title CurveSwapper_v1
/// @notice ISwapExecutor implementation for Curve pools (both StableSwap and crypto
///         families). Each registered pair stores its target pool, the pool's family (which
///         decides the `exchange` ABI — see CurveExchangeLib), the two coin indices, and a
///         flag selecting `exchange` vs `exchange_underlying` (for lending / meta pools that
///         wrap aTokens or cTokens).
/// @dev There is no canonical Curve router across chains — pools are addressed directly,
///      so the per-pair config IS the pool address. Approval target is therefore the pool
///      itself (cleared to zero after every swap).
///
///      `exchange` is invoked through CurveExchangeLib: a low-level call encoded per pool
///      family, with `amountOut` computed via post-call balance delta of `toToken` (agnostic
///      to void-return vs uint256-return pools; also catches pools that round / charge a fee).
///
///      Security:
///      - Pool address and family come from governance-gated `setRoute` storage; never
///        caller-supplied. A wrong family is a mis-configuration: a crypto pool SWALLOWS the
///        int128 selector via its Vyper `__default__` (silent no-op) — which the post-call
///        balance check then catches, but configure the family from the pool's real ABI
///        (verified on-chain) rather than relying on that backstop.
///      - Approval to the pool is reset to zero after every swap.
///      - Reentrancy guarded (transient storage) — some Curve pools call back via ERC-777
///        or hook-style underlyings.
///      - Slippage enforced by both the pool's own `min_dy` and the post-call balance check.
/// @custom:oz-upgrades-unsafe-allow constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner)
contract CurveSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    /// @notice Role allowing an address to configure Curve routes via setRoute.
    uint256 public constant ROUTE_SETTER_ROLE = _ROLE_0;

    /// @notice Per-pair route configuration.
    /// @param pool Curve pool to call.
    /// @param i Index of `fromToken` in the pool.
    /// @param j Index of `toToken` in the pool.
    /// @param useUnderlying If true call `exchange_underlying`; otherwise `exchange`.
    /// @param kind The pool's Curve family — decides the `exchange` ABI (int128 StableSwap
    ///        vs uint256 crypto). Governance-declared from the pool's real ABI.
    struct CurveRoute {
        address pool;
        int128 i;
        int128 j;
        bool useUnderlying;
        CurveExchangeLib.CurvePoolKind kind;
    }

    error NoRouteConfigured(address fromToken, address toToken);
    error InvalidRoute();

    event RouteSet(
        address indexed fromToken,
        address indexed toToken,
        address indexed pool,
        CurveExchangeLib.CurvePoolKind kind,
        int128 i,
        int128 j,
        bool useUnderlying
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.CurveSwapper_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.CurveSwapper_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _CURVE_SWAPPER_STORAGE =
        0x4cea0b39841df6539b02d75c8fa455a6d979caad65ff8d3cccd31047aec4a400;

    struct CurveSwapperStorage {
        mapping(address from => mapping(address to => CurveRoute)) routes;
    }

    function _getCurveSwapperStorage() private pure returns (CurveSwapperStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _CURVE_SWAPPER_STORAGE
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    /// @notice Retrieve the configured Curve route for a token pair.
    function routes(address fromToken, address toToken) external view returns (CurveRoute memory) {
        return _getCurveSwapperStorage().routes[fromToken][toToken];
    }

    /// @notice Set the Curve route for a token pair. Zero pool clears the route.
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @param pool Curve pool to call.
    /// @param kind The pool's Curve family (StableSwap int128 vs crypto uint256 `exchange`
    ///        ABI). Declare it from the pool's real ABI, verified on-chain — a crypto pool
    ///        silently swallows int128-encoded calls via its Vyper `__default__`.
    /// @param i Coin index of `fromToken` in the pool.
    /// @param j Coin index of `toToken` in the pool.
    /// @param useUnderlying Call `exchange_underlying` instead of `exchange`.
    function setRoute(
        address fromToken,
        address toToken,
        address pool,
        CurveExchangeLib.CurvePoolKind kind,
        int128 i,
        int128 j,
        bool useUnderlying
    ) external onlyOwnerOrRoles(ROUTE_SETTER_ROLE) {
        if (pool != address(0)) {
            Token.ensureContract(pool);
            if (i == j || i < 0 || j < 0) {
                revert InvalidRoute();
            }
        }
        _getCurveSwapperStorage().routes[fromToken][toToken] = CurveRoute({
            pool: pool,
            i: i,
            j: j,
            useUnderlying: useUnderlying,
            kind: kind
        });
        emit RouteSet(fromToken, toToken, pool, kind, i, j, useUnderlying);
    }

    /// @inheritdoc ISwapExecutor
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOutPerUnitIn
    ) external override nonReentrant returns (uint256 amountOut) {
        (amountOut, ) = _swapEnvelope(fromToken, toToken, amountIn, minAmountOutPerUnitIn, "");
    }

    /// @dev The pool leg: resolve the governance-set route, approve exactly `amountIn`,
    ///      exchange through CurveExchangeLib (encoded per the route's pool family), reset
    ///      the approval. `minAmountOut` is forwarded as the pool's own `min_dy` for an
    ///      early revert; the envelope re-checks it authoritatively.
    function _execute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory
    ) internal override {
        CurveRoute memory route = _getCurveSwapperStorage().routes[fromToken][toToken];
        if (route.pool == address(0)) {
            revert NoRouteConfigured(fromToken, toToken);
        }

        IERC20(fromToken).forceApprove(route.pool, amountIn);

        CurveExchangeLib.exchange(
            route.pool,
            route.kind,
            route.useUnderlying,
            route.i,
            route.j,
            amountIn,
            minAmountOut
        );

        IERC20(fromToken).forceApprove(route.pool, 0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
