// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapper} from "@harbor-swap/interfaces/ISwapper.sol";
import {ISwapperConfig} from "@harbor-swap/interfaces/ISwapperConfig.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";

/// @title MockSwapper
/// @notice Fixed-rate swapper for testing. Acts as both the Swapper_v1 registry (ISwapper +
///         ISwapperConfig) and a swap executor (ISwapExecutor) in a single contract, so tests
///         need only one address for both roles. Swaps at a configurable rate; no DEX dependency.
/// @dev Proxy-compatible: deploy via the deploy script's deploySwapper() using the
///      deploySwapperImplementation() override. The initialize() signature matches Swapper_v1
///      so the same abi.encodeCall(Swapper_v1.initialize, ...) initData works unchanged.
// solhint-disable-next-line contract-name-capwords
contract MockSwapper is Initializable, UUPSUpgradeable, ISwapper, ISwapperConfig, ISwapExecutor {
    using SafeERC20 for IERC20;

    /// @dev Stored from initialize's pendingOwner_ arg so _transferAllOwnerships() can call owner().
    address private _owner;

    /// @notice Fixed rate: amountOut = amountIn * rate / 1e18. Defaults to 1:1.
    uint256 public rate;

    /// @notice If true, the next swap will revert (for testing error handling).
    bool public shouldRevert;

    /// @notice Recorded swap executors from setRoute calls.
    ///         Non-zero value = route available. Returns address(this) so HY can call
    ///         swap() on this same mock contract.
    mapping(address => mapping(address => address)) public recordedExecutors;

    /// @notice Recorded fee ratios from setRoute calls.
    mapping(address => mapping(address => uint256)) public recordedFeeRatios;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Matches Swapper_v1.initialize signature so deploy scripts work unchanged with this mock.
    function initialize(address, address pendingOwner_) external initializer {
        _owner = pendingOwner_;
        rate = 1 ether; // default 1:1
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    /// @inheritdoc ISwapperConfig
    /// @dev When swapExecutor is address(0) the route is cleared; otherwise we store address(this)
    ///      as the executor so HY's approval and swap call land on this mock.
    function setRoute(address fromToken, address toToken, address swapExecutor, uint256 feeRatio) external override {
        recordedExecutors[fromToken][toToken] = swapExecutor;
        recordedFeeRatios[fromToken][toToken] = swapExecutor != address(0) ? feeRatio : 0;
        emit RouteUpdated(fromToken, toToken, swapExecutor, recordedFeeRatios[fromToken][toToken]);
    }

    /// @inheritdoc ISwapper
    function getRoute(
        address fromToken,
        address toToken,
        uint256 /* amountIn */
    ) external view override returns (RouteInfo memory routeInfo) {
        address exec = recordedExecutors[fromToken][toToken];
        routeInfo = RouteInfo({
            target: toToken,
            available: exec != address(0),
            amountOut: 0,
            quoted: false,
            routeCostRatio: exec != address(0) ? recordedFeeRatios[fromToken][toToken] : 0,
            swapExecutor: exec
        });
    }

    /// @inheritdoc ISwapper
    function getRoutesFrom(
        address fromToken,
        address[] calldata targets,
        uint256 /* amountIn */
    ) external view override returns (RouteInfo[] memory routeInfos) {
        routeInfos = new RouteInfo[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            address exec = recordedExecutors[fromToken][targets[i]];
            routeInfos[i] = RouteInfo({
                target: targets[i],
                available: exec != address(0),
                amountOut: 0,
                quoted: false,
                routeCostRatio: exec != address(0) ? recordedFeeRatios[fromToken][targets[i]] : 0,
                swapExecutor: exec
            });
        }
    }

    /// @inheritdoc ISwapExecutor
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override returns (uint256 amountOut) {
        if (shouldRevert) {
            revert("MockSwapper: forced revert");
        }

        amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= minAmountOut, "MockSwapper: slippage");

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override {} // permissive in tests
}
