// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @notice Mock Balancer V2 Vault for BalancerSwapper_v1 tests. Implements the SingleSwap
///         path with the exact struct layout the real Vault uses, so the executor's call
///         is exercised end-to-end. Rate, revert behaviour, and reentrancy target are
///         configurable.
contract MockBalancerVault {
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

    uint256 public rate = 1e18;
    bool public shouldRevert;
    bool public honourLimit = true;
    address public reentrantTarget;
    bytes public reentrantCalldata;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    /// @notice `false` is the "liar" mode: under-deliver (per `rate`) while ignoring `limit`,
    ///         reporting success — so tests can prove the executor's own balance-delta floor
    ///         protects the caller.
    function setHonourLimit(bool honour_) external {
        honourLimit = honour_;
    }

    function setReentrantCall(address target_, bytes calldata calldata_) external {
        reentrantTarget = target_;
        reentrantCalldata = calldata_;
    }

    function swap(
        SingleSwap calldata singleSwap,
        FundManagement calldata funds,
        uint256 limit,
        uint256 /* deadline */
    ) external payable returns (uint256 amountCalculated) {
        if (shouldRevert) {
            revert("MockBalancerVault: forced revert");
        }
        require(singleSwap.kind == SwapKind.GIVEN_IN, "MockBalancerVault: only GIVEN_IN");

        IERC20(singleSwap.assetIn).transferFrom(funds.sender, address(this), singleSwap.amount);
        amountCalculated = (singleSwap.amount * rate) / 1e18;
        if (honourLimit) {
            // The real Vault reverts Errors.SWAP_LIMIT as "BAL#507".
            require(amountCalculated >= limit, "BAL#507");
        }
        MockERC20(singleSwap.assetOut).mint(funds.recipient, amountCalculated);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory ret) = reentrantTarget.call(reentrantCalldata);
            if (!ok) {
                // Bubble the inner revert unchanged so tests can pin the exact error the
                // re-entered contract raised (e.g. the reentrancy guard's).
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
