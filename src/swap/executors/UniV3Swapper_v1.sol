// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";

/// @title UniV3Swapper_v1
/// @notice ISwapExecutor implementation using Uniswap v3 exactInput for all swaps.
///         Stores encoded route paths per token pair; registered in Swapper_v1 as the
///         swap executor for pairs that use UniV3 liquidity.
/// @dev Security properties:
///      - Router approval target is an immutable constructor arg, never caller-supplied.
///      - Approval cleared to zero after every swap.
///      - Reentrancy protected via transient storage guard.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance — false positive: initialize(address,address) ABI matches IHarborYieldEntryInit by coincidence; the two addresses are (deployerOwner, pendingOwner), not entry init args
contract UniV3Swapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    using SafeERC20 for IERC20;

    error NoPathConfigured(address fromToken, address toToken);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    event PathSet(address indexed fromToken, address indexed toToken, bytes path);

    /// @notice Role allowing an address to configure swap paths via setPath.
    uint256 public constant PATH_SETTER_ROLE = _ROLE_0;

    ISwapRouter public immutable ROUTER;

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.UniV3Swapper_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.UniV3Swapper_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _UNIV3_SWAPPER_STORAGE =
        0xb58ff39df7f79777767b535a2624f02d14704811751af26be9cd34beb7b5b200;

    struct UniV3SwapperStorage {
        /// @notice Encoded UniV3 exactInput route per token pair.
        ///         Single-hop: abi.encodePacked(from, fee, to) — 43 bytes.
        ///         Multi-hop:  abi.encodePacked(from, fee1, mid, fee2, to) — 66 bytes.
        ///         Empty = no path configured for this pair.
        mapping(address from => mapping(address to => bytes)) paths;
    }

    function _getUniV3SwapperStorage() private pure returns (UniV3SwapperStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _UNIV3_SWAPPER_STORAGE
        }
    }

    constructor(address router_) {
        _disableInitializers();
        ROUTER = ISwapRouter(router_);
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    function paths(address from, address to) external view returns (bytes memory) {
        return _getUniV3SwapperStorage().paths[from][to];
    }

    /// @notice Store a UniV3 exactInput path for a token pair.
    /// @param fromToken Token to swap from.
    /// @param toToken Token to swap to.
    /// @param path Encoded UniV3 path bytes (abi.encodePacked route).
    function setPath(
        address fromToken,
        address toToken,
        bytes calldata path
    ) external onlyOwnerOrRoles(PATH_SETTER_ROLE) {
        _getUniV3SwapperStorage().paths[fromToken][toToken] = path;
        emit PathSet(fromToken, toToken, path);
    }

    /// @inheritdoc ISwapExecutor
    // slither-disable-next-line timestamp — deadline = block.timestamp is intentional: slippage is already enforced by minAmountOut; a future deadline would let searchers delay execution to a block where price slips just inside the limit
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        bytes memory path = _getUniV3SwapperStorage().paths[fromToken][toToken];
        if (path.length == 0) {
            revert NoPathConfigured(fromToken, toToken);
        }
        IERC20(fromToken).forceApprove(address(ROUTER), amountIn);
        amountOut = ROUTER.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        );
        IERC20(fromToken).forceApprove(address(ROUTER), 0);

        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountOut, minAmountOut);
        }
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
