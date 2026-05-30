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
        require(amountCalculated >= limit, "MockBalancerVault: slippage");
        MockERC20(singleSwap.assetOut).mint(funds.recipient, amountCalculated);

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockBalancerVault: reentrant call failed");
        }
    }
}
