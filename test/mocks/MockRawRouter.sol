// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @notice Mock raw-calldata router for Swapper_v1 1inch-path tests.
///         The Swapper calls this via low-level call(data) where data encodes `swap(...)`.
///         Pulls fromToken from msg.sender (via pre-approval) and mints toToken to msg.sender.
///         Rate, revert behaviour, and reentrancy target are configurable.
contract MockRawRouter {
    uint256 public rate = 1e18;
    bool public shouldRevert;
    address public reentrantTarget;
    bytes public reentrantCalldata;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setReentrantCall(address target_, bytes calldata calldata_) external {
        reentrantTarget = target_;
        reentrantCalldata = calldata_;
    }

    /// @notice Encode this as `data` in Swapper_v1.swap(..., data).
    function swap(address fromToken, address toToken, uint256 amountIn) external returns (uint256 amountOut) {
        if (shouldRevert) {
            revert("MockRawRouter: forced revert");
        }

        IERC20(fromToken).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * rate) / 1e18;
        MockERC20(toToken).mint(msg.sender, amountOut);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockRawRouter: reentrant call failed");
        }
    }
}
