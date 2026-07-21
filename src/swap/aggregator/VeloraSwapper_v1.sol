// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {Token} from "@bao/Token.sol";

import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {VeloraV62Selectors} from "@harbor-swap/aggregator/VeloraV62Selectors.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";

/// @title VeloraSwapper_v1
/// @notice Aggregator adapter that executes opaque keeper-built calldata against a fixed
///         router (Velora Augustus v6.2 on production). The SwapExecutorBase envelope
///         enforces slippage by post-call balance delta and refunds any unspent `fromToken`
///         to the caller.
/// @dev Security properties:
///      - Router is an immutable constructor arg, never caller-supplied.
///      - Approval is forced to `amountIn` before the call and reset to zero after.
///      - Reentrancy protected (transient storage guard).
///      - Stateless beyond the router immutable: open access is safe because the adapter
///        only ever spends `msg.sender`'s pre-approved balance and returns proceeds to
///        `msg.sender`. Authorization gating lives at the consumer (e.g.
///        `HarborYield_v1.redistribute` role gate).
///      - `routerData` must be at least 4 bytes and start with a Velora v6.2 allowlisted
///        selector (`swapExactAmountIn` or `swapExactAmountOut`). Other router entrypoints
///        are rejected. The selector check is defence-in-depth; the envelope's balance-delta
///        accounting (with `ZeroAmountOut` fatal even at `minAmountOut == 0`) is what makes
///        hostile calldata unprofitable.
///      - This adapter is upgradeable (UUPS) so the router immutable can be repointed
///        across major aggregator upgrades by deploying a new implementation.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) ABI matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner), not entry init args
contract VeloraSwapper_v1 is// solhint-disable-line contract-name-capwords
 IAggregatorSwapper, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    /// @notice The fixed router this adapter calls. Augustus v6.2 lives at the same
    ///         address on every supported Velora chain.
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
    // The event is emitted after the envelope has fully reconciled balances and paid the
    // caller; reentrancy is blocked by nonReentrant.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) external override nonReentrant returns (uint256 amountOut) {
        _validateRouterData(routerData);
        uint256 refundedIn;
        (amountOut, refundedIn) = _swapEnvelope(fromToken, toToken, amountIn, minAmountOut, routerData);
        emit AggregatorSwap(msg.sender, fromToken, toToken, amountIn, amountOut, refundedIn);
    }

    /// @dev The router leg: approve exactly `amountIn`, hand the keeper-built calldata to the
    ///      immutable router, reset the approval. The low-level call is intentional — the
    ///      calldata is opaque by design. `minAmountOut` is not forwarded (Velora carries its
    ///      own bound inside the calldata); the envelope enforces it authoritatively.
    function _execute(
        address fromToken,
        address,
        uint256 amountIn,
        uint256,
        bytes memory routerData
    ) internal override {
        IERC20(fromToken).forceApprove(ROUTER, amountIn);
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory revertData) = ROUTER.call(routerData); // solhint-disable-line avoid-low-level-calls
        IERC20(fromToken).forceApprove(ROUTER, 0);
        if (!ok) {
            revert RouterCallFailed(revertData);
        }
    }

    /// @dev Harbor Option A: only Velora v6.2 Market API swap entrypoints.
    function _validateRouterData(bytes calldata routerData) private pure {
        if (routerData.length < 4) {
            revert RouterCalldataTooShort();
        }
        bytes4 selector = bytes4(routerData[:4]);
        if (
            selector != VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN && selector != VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT
        ) {
            revert DisallowedRouterSelector(selector);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
