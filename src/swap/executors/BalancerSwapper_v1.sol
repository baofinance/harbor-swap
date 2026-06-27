// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";

/// @notice Minimal subset of Balancer V2 IVault required for single-asset swaps.
/// @dev Full ABI lives in @balancer-labs/v2-interfaces; we redeclare the swap-related
///      types here to avoid pulling the whole package as a dependency. Field layout and
///      selectors must match the on-chain Vault — verified against
///      https://docs.balancer.fi/reference/swaps/single-swap.html.
interface IBalancerV2Vault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(
        SingleSwap calldata singleSwap,
        FundManagement calldata funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 amountCalculated);
}

/// @title BalancerSwapper_v1
/// @notice ISwapExecutor implementation for Balancer V2 single-asset swaps. Each
///         registered pair stores the Balancer poolId; assetIn / assetOut are derived
///         from the (fromToken, toToken) arguments at call time.
/// @dev Architectural notes:
///      - Balancer V2 routes every swap through one Vault per chain (immutable). That
///        Vault is the only approval target the executor ever holds, and we reset the
///        allowance to zero after each call.
///      - We use `SwapKind.GIVEN_IN` exclusively: `amount = amountIn`, `limit = minOut`.
///        The Vault returns `amountCalculated = amountOut`, but we also reconcile via
///        post-call balance delta as a defence-in-depth check.
///      - `FundManagement.fromInternalBalance / toInternalBalance` are both false:
///        Harbor never holds Vault internal balance, so external transfers in/out
///        keep accounting trivial.
///      - Multi-hop is intentionally out of scope: Harbor swaps are between pegged
///        assets that share single pools; a future BalancerBatchSwapper_v1 can wrap
///        `Vault.batchSwap` if a need emerges.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner)
contract BalancerSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Role allowing an address to configure Balancer routes via setRoute.
    uint256 public constant ROUTE_SETTER_ROLE = _ROLE_0;

    /// @notice The Balancer V2 Vault this executor calls. Set once in the constructor.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable VAULT; // solhint-disable-line immutable-vars-naming

    error NoRouteConfigured(address fromToken, address toToken);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    event RouteSet(address indexed fromToken, address indexed toToken, bytes32 poolId);

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.BalancerSwapper_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.BalancerSwapper_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _BALANCER_SWAPPER_STORAGE =
        0xea3800a75e0cb8ce4b65ed20b5c4b89176b433c382f0671090007010e85e6500;

    struct BalancerSwapperStorage {
        /// @notice Per-pair Balancer pool ID. bytes32(0) = no route configured.
        mapping(address from => mapping(address to => bytes32)) poolIds;
    }

    function _getBalancerSwapperStorage() private pure returns (BalancerSwapperStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _BALANCER_SWAPPER_STORAGE
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address vault_) {
        _disableInitializers();
        Token.ensureContract(vault_);
        // slither-disable-next-line missing-zero-check
        VAULT = vault_;
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    /// @notice Retrieve the configured Balancer pool ID for a token pair.
    function poolIds(address fromToken, address toToken) external view returns (bytes32) {
        return _getBalancerSwapperStorage().poolIds[fromToken][toToken];
    }

    /// @notice Set the Balancer pool ID for a token pair. Pass bytes32(0) to clear.
    function setRoute(address fromToken, address toToken, bytes32 poolId) external onlyOwnerOrRoles(ROUTE_SETTER_ROLE) {
        _getBalancerSwapperStorage().poolIds[fromToken][toToken] = poolId;
        emit RouteSet(fromToken, toToken, poolId);
    }

    /// @inheritdoc ISwapExecutor
    // slither-disable-next-line timestamp — deadline = block.timestamp matches UniV3Swapper rationale: slippage is already enforced by minAmountOut and balance delta
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        bytes32 poolId = _getBalancerSwapperStorage().poolIds[fromToken][toToken];
        if (poolId == bytes32(0)) {
            revert NoRouteConfigured(fromToken, toToken);
        }

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 toBalanceBefore = IERC20(toToken).balanceOf(address(this));

        IERC20(fromToken).forceApprove(VAULT, amountIn);

        amountOut = IBalancerV2Vault(VAULT).swap(
            IBalancerV2Vault.SingleSwap({
                poolId: poolId,
                kind: IBalancerV2Vault.SwapKind.GIVEN_IN,
                assetIn: fromToken,
                assetOut: toToken,
                amount: amountIn,
                userData: ""
            }),
            IBalancerV2Vault.FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: payable(address(this)),
                toInternalBalance: false
            }),
            minAmountOut,
            block.timestamp
        );

        IERC20(fromToken).forceApprove(VAULT, 0);

        // Defence in depth: confirm the Vault's reported amount equals balance delta.
        uint256 received = IERC20(toToken).balanceOf(address(this)) - toBalanceBefore;
        if (received < minAmountOut || received < amountOut) {
            revert InsufficientOutput(received, minAmountOut);
        }
        amountOut = received;

        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
