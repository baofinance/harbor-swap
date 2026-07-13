// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @notice Mock Curve pool that mimics both `exchange` and `exchange_underlying` selectors.
///         Pulls `dx` of the coin at index `i` from msg.sender (via pre-approval), mints
///         `dx * rate / 1e18` of the coin at index `j` to msg.sender. Used to drive
///         CurveSwapper_v1 tests through the same low-level call path the executor uses
///         on real pools.
contract MockCurvePool {
    /// @notice coin[i] is the token at index `i` in the pool.
    mapping(int128 => address) public coins;
    /// @notice underlying[i] is the token at index `i` if the executor calls
    ///         `exchange_underlying` (lending / meta pool wrap).
    mapping(int128 => address) public underlying;

    uint256 public rate = 1e18;
    bool public shouldRevert;
    bool public returnVoid; // legacy 3pool-style behaviour
    address public reentrantTarget;
    bytes public reentrantCalldata;

    function setCoin(int128 idx, address token) external {
        coins[idx] = token;
    }

    function setUnderlying(int128 idx, address token) external {
        underlying[idx] = token;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setReturnVoid(bool returnVoid_) external {
        returnVoid = returnVoid_;
    }

    function setReentrantCall(address target_, bytes calldata calldata_) external {
        reentrantTarget = target_;
        reentrantCalldata = calldata_;
    }

    /// @notice Curve `exchange(int128, int128, uint256, uint256)`.
    ///         Returns nothing when `returnVoid` is true to mimic legacy 3pool ABI; the
    ///         executor handles both via balance delta.
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        dy = _doSwap(coins[i], coins[j], dx, min_dy);
        if (returnVoid) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                return(0, 0)
            }
        }
    }

    /// @notice Curve `exchange_underlying(int128, int128, uint256, uint256)`.
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        dy = _doSwap(underlying[i], underlying[j], dx, min_dy);
        if (returnVoid) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                return(0, 0)
            }
        }
    }

    function _doSwap(address tokenIn, address tokenOut, uint256 dx, uint256 min_dy) private returns (uint256 dy) {
        if (shouldRevert) {
            revert("MockCurvePool: forced revert");
        }
        IERC20(tokenIn).transferFrom(msg.sender, address(this), dx);
        dy = (dx * rate) / 1e18;
        require(dy >= min_dy, "MockCurvePool: slippage");
        MockERC20(tokenOut).mint(msg.sender, dy);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockCurvePool: reentrant call failed");
        }
    }
}
