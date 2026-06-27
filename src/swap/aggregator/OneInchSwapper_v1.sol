// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";

import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {OneInchV6Selectors} from "@harbor-swap/aggregator/OneInchV6Selectors.sol";

/// @title OneInchSwapper_v1
/// @notice Aggregator adapter that executes opaque keeper-built calldata against a fixed
///         router (1inch AggregationRouterV6 on production). Slippage is enforced by
///         post-call balance delta; any unspent `fromToken` (1inch `_PARTIAL_FILL`) is
///         refunded to the caller.
/// @dev Security properties:
///      - Router is an immutable constructor arg, never caller-supplied.
///      - Approval is forced to `amountIn` before the call and reset to zero after.
///      - Reentrancy protected (transient storage guard).
///      - Stateless beyond the router immutable: open access is safe because the adapter
///        only ever spends `msg.sender`'s pre-approved balance and returns proceeds to
///        `msg.sender`. Authorization gating lives at the consumer (e.g.
///        `HarborYield_v1.executeAggregatorSwap` role gate).
///      - `routerData` must be at least 4 bytes and start with `OneInchV6Selectors.SWAP`
///        (1inch v6 `swap(address,tuple,bytes)`). Other router entrypoints are rejected.
///      - This adapter is upgradeable (UUPS) so the router immutable can be repointed
///        across major aggregator upgrades by deploying a new implementation.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) ABI matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner), not entry init args
contract OneInchSwapper_v1 is// solhint-disable-line contract-name-capwords
 IAggregatorSwapper, HarborOwnableRoles, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The fixed router this adapter calls. On most chains 1inch v6 lives at the
    ///         CREATE2-deterministic address 0x111111125421cA6dC452d289314280a0f8842A65.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable ROUTER; // solhint-disable-line immutable-vars-naming

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address router_) {
        _disableInitializers();
        Token.ensureContract(router_);
        // slither-disable-next-line missing-zero-check
        ROUTER = router_;
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    /// @inheritdoc IAggregatorSwapper
    // Low-level call to the immutable router is intentional (calldata is keeper-built and
    // intentionally opaque). Reentrancy is blocked by nonReentrant, and the event is emitted
    // after the external call has fully unwound and balances have been reconciled.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) external override nonReentrant returns (uint256 amountOut) {
        if (fromToken == toToken) {
            IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(toToken).safeTransfer(msg.sender, amountIn);
            emit AggregatorSwap(msg.sender, fromToken, toToken, amountIn, amountIn, 0);
            return amountIn;
        }

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 fromBalanceBefore = IERC20(fromToken).balanceOf(address(this));
        uint256 toBalanceBefore = IERC20(toToken).balanceOf(address(this));

        _validateRouterData(routerData);

        IERC20(fromToken).forceApprove(ROUTER, amountIn);
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory revertData) = ROUTER.call(routerData); // solhint-disable-line avoid-low-level-calls
        IERC20(fromToken).forceApprove(ROUTER, 0);
        if (!ok) {
            revert RouterCallFailed(revertData);
        }

        amountOut = IERC20(toToken).balanceOf(address(this)) - toBalanceBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientAmountOut(amountOut, minAmountOut);
        }

        uint256 fromBalanceAfter = IERC20(fromToken).balanceOf(address(this));
        uint256 refundedIn =
            fromBalanceAfter > (fromBalanceBefore - amountIn) ? fromBalanceAfter - (fromBalanceBefore - amountIn) : 0;
        if (refundedIn > 0) {
            IERC20(fromToken).safeTransfer(msg.sender, refundedIn);
        }
        IERC20(toToken).safeTransfer(msg.sender, amountOut);

        emit AggregatorSwap(msg.sender, fromToken, toToken, amountIn, amountOut, refundedIn);
    }

    /// @dev Harbor Option A: only 1inch v6 `swap(address,tuple,bytes)` calldata from the Swap API.
    function _validateRouterData(bytes calldata routerData) private pure {
        if (routerData.length < 4) {
            revert RouterCalldataTooShort();
        }
        bytes4 selector = bytes4(routerData[:4]);
        if (selector != OneInchV6Selectors.SWAP) {
            revert DisallowedRouterSelector(selector);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
