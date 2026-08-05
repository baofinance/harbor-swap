// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {VeloraV62Selectors} from "@harbor-swap/aggregator/VeloraV62Selectors.sol";

/// @notice Test double for Velora Augustus v6.2 `swapExactAmountIn` / `swapExactAmountOut`.
///         Production keepers supply Market API-built calldata; unit tests use this shape.
contract MockAugustusV62 {
    /// @notice Mirrors the v6.2 router GenericData tuple used in keeper calldata.
    struct GenericData {
        address srcToken;
        address destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address beneficiary;
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

    /// @notice Velora v6.2 `swapExactAmountIn` entrypoint.
    function swapExactAmountIn(
        address,
        GenericData calldata swapData,
        uint256,
        bytes calldata,
        bytes calldata
    ) external payable returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare) {
        (, receivedAmount) = _fill(swapData.srcToken, swapData.destToken, swapData.fromAmount);
        paraswapShare = 0;
        partnerShare = 0;
    }

    /// @notice Velora v6.2 `swapExactAmountOut` entrypoint. Exact-out semantics: buy exactly
    ///         `swapData.toAmount`, spending whatever that costs at the current rate, bounded
    ///         above by `swapData.fromAmount` (the maximum the caller will pay). Spending less
    ///         than the maximum is the NORMAL case here, not a partial fill — so
    ///         `partialFillRatio` deliberately does not apply.
    function swapExactAmountOut(
        address,
        GenericData calldata swapData,
        uint256,
        bytes calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        if (shouldRevert) {
            revert("MockAugustusV62: forced revert");
        }

        receivedAmount = swapData.toAmount;
        // Rounded up: the venue never sells the output for less than it is worth.
        spentAmount = (receivedAmount * 1e18 + rate - 1) / rate;
        // The bound is real — every exact-out API caps the input — but this message is the
        // mock's own and has NOT been checked against the deployed Augustus.
        if (spentAmount > swapData.fromAmount) {
            revert("MockAugustusV62: exceeds maxAmountIn");
        }

        IERC20(swapData.srcToken).transferFrom(msg.sender, address(this), spentAmount);
        MockERC20(swapData.destToken).mint(msg.sender, receivedAmount);
        _maybeReenter();

        paraswapShare = 0;
        partnerShare = 0;
    }

    function _fill(
        address fromToken,
        address toToken,
        uint256 fromAmount
    ) private returns (uint256 spentAmount, uint256 receivedAmount) {
        if (shouldRevert) {
            revert("MockAugustusV62: forced revert");
        }

        spentAmount = (fromAmount * partialFillRatio) / 1e18;
        IERC20(fromToken).transferFrom(msg.sender, address(this), spentAmount);
        receivedAmount = (spentAmount * rate) / 1e18;
        MockERC20(toToken).mint(msg.sender, receivedAmount);
        _maybeReenter();
    }

    function _maybeReenter() private {
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

    /// @dev Confirms this mock exposes the same selectors the adapter allowlists.
    function swapExactAmountInSelector() external pure returns (bytes4) {
        return VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN;
    }

    function swapExactAmountOutSelector() external pure returns (bytes4) {
        return VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT;
    }
}
