// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";

/// @title CurveSwapper_v1
/// @notice ISwapExecutor implementation for Curve StableSwap-style pools. Each registered
///         pair stores its target pool, the two int128 coin indices, and a flag selecting
///         `exchange` vs `exchange_underlying` (for lending / meta pools that wrap aTokens
///         or cTokens).
/// @dev There is no canonical Curve router across chains — pools are addressed directly,
///      so the per-pair config IS the pool address. Approval target is therefore the pool
///      itself (cleared to zero after every swap).
///
///      Older StableSwap pools (e.g. 3pool) declare `exchange` as `void` while newer ones
///      (NG, factory, crypto-stable) return `uint256`. To stay agnostic, this executor
///      uses a low-level call and computes `amountOut` via post-call balance delta of
///      `toToken` — that also catches pools that round / charge a fee.
///
///      Security:
///      - Pool address comes from governance-gated `setRoute` storage; never caller-supplied.
///      - Approval to the pool is reset to zero after every swap.
///      - Reentrancy guarded (transient storage) — some Curve pools call back via ERC-777
///        or hook-style underlyings.
///      - Slippage enforced by both the pool's own `min_dy` and the post-call balance check.
/// @custom:oz-upgrades-unsafe-allow constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner)
contract CurveSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Role allowing an address to configure Curve routes via setRoute.
    uint256 public constant ROUTE_SETTER_ROLE = _ROLE_0;

    /// @notice Per-pair route configuration.
    /// @param pool Curve pool to call.
    /// @param i Index of `fromToken` in the pool (int128 to match Curve's ABI).
    /// @param j Index of `toToken` in the pool.
    /// @param useUnderlying If true call `exchange_underlying`; otherwise `exchange`.
    struct CurveRoute {
        address pool;
        int128 i;
        int128 j;
        bool useUnderlying;
    }

    error NoRouteConfigured(address fromToken, address toToken);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error PoolCallFailed(bytes revertData);
    error InvalidRoute();

    event RouteSet(
        address indexed fromToken,
        address indexed toToken,
        address indexed pool,
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
    /// @param i Coin index of `fromToken` in the pool.
    /// @param j Coin index of `toToken` in the pool.
    /// @param useUnderlying Call `exchange_underlying` instead of `exchange`.
    function setRoute(
        address fromToken,
        address toToken,
        address pool,
        int128 i,
        int128 j,
        bool useUnderlying
    ) external onlyOwnerOrRoles(ROUTE_SETTER_ROLE) {
        if (pool != address(0)) {
            Token.ensureContract(pool);
            if (i == j) {
                revert InvalidRoute();
            }
        }
        _getCurveSwapperStorage().routes[fromToken][toToken] = CurveRoute({
            pool: pool,
            i: i,
            j: j,
            useUnderlying: useUnderlying
        });
        emit RouteSet(fromToken, toToken, pool, i, j, useUnderlying);
    }

    /// @inheritdoc ISwapExecutor
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        CurveRoute memory route = _getCurveSwapperStorage().routes[fromToken][toToken];
        if (route.pool == address(0)) {
            revert NoRouteConfigured(fromToken, toToken);
        }

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 toBalanceBefore = IERC20(toToken).balanceOf(address(this));

        IERC20(fromToken).forceApprove(route.pool, amountIn);

        // Curve `exchange*` signatures take (int128 i, int128 j, uint256 dx, uint256 min_dy).
        // We use a low-level call so the executor is agnostic to legacy void-return vs
        // newer uint256-return pools; amountOut is reconciled via balance delta below.
        bytes memory callData =
            route.useUnderlying
                ? abi.encodeWithSignature(
                    "exchange_underlying(int128,int128,uint256,uint256)",
                    route.i,
                    route.j,
                    amountIn,
                    minAmountOut
                )
                : abi.encodeWithSignature(
                    "exchange(int128,int128,uint256,uint256)",
                    route.i,
                    route.j,
                    amountIn,
                    minAmountOut
                );

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory revertData) = route.pool.call(callData);

        IERC20(fromToken).forceApprove(route.pool, 0);

        if (!ok) {
            revert PoolCallFailed(revertData);
        }

        amountOut = IERC20(toToken).balanceOf(address(this)) - toBalanceBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountOut, minAmountOut);
        }

        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
