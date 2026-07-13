// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {OneInchV6Selectors} from "@harbor-swap/aggregator/OneInchV6Selectors.sol";

/// @notice Test double for 1inch Aggregation Router V6 `swap(address,SwapDescription,bytes)`.
///         The `data` argument must be `abi.encode(fromToken, toToken, amountIn)` for the mock
///         fill path. Production keepers supply API-built calldata; unit tests use this shape.
contract MockAggregationRouterV6 {
    /// @notice Mirrors the v6 router SwapDescription tuple used in keeper calldata.
    struct SwapDescription {
        address srcToken;
        address dstToken;
        address srcReceiver;
        address dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    uint256 public rate = 1e18;
    bool public shouldRevert;
    uint256 public partialFillRatio = 1e18;
    address public reentrantTarget;
    bytes public reentrantCalldata;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setPartialFillRatio(uint256 ratio_) external {
        partialFillRatio = ratio_;
    }

    function setReentrantCall(address target_, bytes calldata calldata_) external {
        reentrantTarget = target_;
        reentrantCalldata = calldata_;
    }

    /// @notice 1inch v6 `swap` entrypoint (selector `OneInchV6Selectors.SWAP`).
    function swap(
        address,
        SwapDescription calldata,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount) {
        if (shouldRevert) {
            revert("MockAggregationRouterV6: forced revert");
        }

        (address fromToken, address toToken, uint256 amountIn) = abi.decode(data, (address, address, uint256));
        spentAmount = (amountIn * partialFillRatio) / 1e18;
        IERC20(fromToken).transferFrom(msg.sender, address(this), spentAmount);
        returnAmount = (spentAmount * rate) / 1e18;
        MockERC20(toToken).mint(msg.sender, returnAmount);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockAggregationRouterV6: reentrant call failed");
        }
    }

    /// @dev Confirms this mock exposes the same selector the adapter allowlists.
    function swapSelector() external pure returns (bytes4) {
        return OneInchV6Selectors.SWAP;
    }
}
