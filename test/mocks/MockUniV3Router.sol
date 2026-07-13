// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @notice Mock Uniswap v3 router for Swapper_v1 tests.
///         Pulls fromToken from msg.sender (via pre-approval) and mints toToken to recipient.
///         Rate, revert behaviour, and reentrancy target are configurable.
contract MockUniV3Router {
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

    function exactInput(ISwapRouter.ExactInputParams calldata params) external returns (uint256 amountOut) {
        if (shouldRevert) {
            revert("MockUniV3Router: forced revert");
        }

        // Infer tokenIn from path (first 20 bytes) and tokenOut (last 20 bytes).
        bytes memory path = params.path;
        address tokenIn;
        address tokenOut;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }

        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * rate) / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockUniV3Router: slippage");
        MockERC20(tokenOut).mint(params.recipient, amountOut);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockUniV3Router: reentrant call failed");
        }
    }

    // Stub to satisfy IUniswapV3SwapCallback (required by ISwapRouter inheritance).
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure {}
}
