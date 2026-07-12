// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @notice Shared mechanics for the two Curve pool family mocks. A mock pool must present
///         the SAME observable surface as its real family — including which `exchange`
///         selectors it does NOT implement — so the concrete mocks expose family-correct
///         externals and this base only holds the swap bookkeeping.
/// @dev `honourMinDy = false` is the "liar" mode: the pool under-delivers (per `rate`) and
///      skips its own min_dy check, returning success — modelling a buggy or hostile venue
///      so tests can prove the executor's own balance-delta floor is what actually protects
///      the caller.
abstract contract MockCurvePoolBase {
    /// @notice coin[i] is the token at index `i` in the pool.
    mapping(int128 => address) public coins;

    uint256 public rate = 1e18;
    bool public shouldRevert;
    bool public honourMinDy = true;
    address public reentrantTarget;
    bytes public reentrantCalldata;

    function setCoin(int128 idx, address token) external {
        coins[idx] = token;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setHonourMinDy(bool honour_) external {
        honourMinDy = honour_;
    }

    function setReentrantCall(address target_, bytes calldata calldata_) external {
        reentrantTarget = target_;
        reentrantCalldata = calldata_;
    }

    function _doSwap(address tokenIn, address tokenOut, uint256 dx, uint256 min_dy) internal returns (uint256 dy) {
        if (shouldRevert) {
            revert("MockCurvePool: forced revert");
        }
        IERC20(tokenIn).transferFrom(msg.sender, address(this), dx);
        dy = (dx * rate) / 1e18;
        if (honourMinDy) {
            require(dy >= min_dy, "Slippage");
        }
        MockERC20(tokenOut).mint(msg.sender, dy);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockCurvePool: reentrant call failed");
        }
    }
}
