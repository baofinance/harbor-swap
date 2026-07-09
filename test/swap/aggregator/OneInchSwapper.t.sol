// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests OneInchSwapper_v1: aggregator adapter calling a fixed router with keeper-supplied
// calldata. Verifies v6 selector allowlist, balance-delta slippage, partial-fill refunds,
// approval cleanup, token transfer invariants, and reentrancy guard.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockAggregationRouterV6} from "@harbor-swap-test-mocks/MockAggregationRouterV6.sol";

import {OneInchSwapper_v1} from "@harbor-swap/aggregator/OneInchSwapper_v1.sol";
import {OneInchV6Selectors} from "@harbor-swap/aggregator/OneInchV6Selectors.sol";
import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract OneInchSwapperTest is BaoTest, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    address alice = makeAddr("alice");

    address fromToken;
    address toToken;
    address router;
    address oneInchProxy;

    string constant SALT_PREFIX = "test_oneinch";

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));

        router = address(new MockAggregationRouterV6());
        assertEq(MockAggregationRouterV6(router).swapSelector(), OneInchV6Selectors.SWAP);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployOneInchSwapper(state, router);
        oneInchProxy = _predictAddress("oneInchSwapper");
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    function _swapDescription(
        uint256 amountIn
    ) internal view returns (MockAggregationRouterV6.SwapDescription memory desc) {
        desc = MockAggregationRouterV6.SwapDescription({
            srcToken: fromToken,
            dstToken: toToken,
            srcReceiver: address(0),
            dstReceiver: address(0),
            amount: amountIn,
            minReturnAmount: 0,
            flags: 0
        });
    }

    /// @notice ABI-encoded calldata with leading selector `OneInchV6Selectors.SWAP`.
    function _routerData(uint256 amountIn) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                MockAggregationRouterV6.swap,
                (address(0), _swapDescription(amountIn), abi.encode(fromToken, toToken, amountIn))
            );
    }

    function test_swap_happyPath() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );

        assertEq(amountOut, amountIn, "Mock router default rate 1:1");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    function test_router_immutable_isSet() public view {
        assertEq(OneInchSwapper_v1(oneInchProxy).ROUTER(), router);
    }

    function test_swap_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));

        assertEq(IERC20(fromToken).allowance(oneInchProxy, router), 0);
    }

    function test_swap_sameToken_passthrough() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(fromToken, fromToken, amountIn, amountIn, hex"");

        assertEq(amountOut, amountIn);
        assertEq(IERC20(fromToken).balanceOf(address(this)), amountIn);
    }

    function test_swap_rejectsEmptyCalldata() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert(IAggregatorSwapper.RouterCalldataTooShort.selector);
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, hex"");
    }

    function test_swap_rejectsDisallowedSelector() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        bytes memory badData = abi.encodePacked(bytes4(0xdeadbeef), _routerData(amountIn));

        vm.expectRevert(
            abi.encodeWithSelector(IAggregatorSwapper.DisallowedRouterSelector.selector, bytes4(0xdeadbeef))
        );
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, badData);
    }

    function test_swap_acceptsSwapV6Selector() public view {
        bytes memory data = _routerData(1 ether);
        assertEq(bytes4(data), OneInchV6Selectors.SWAP);
    }

    function test_swap_tokensTransferred() public {
        uint256 amountIn = 3 ether;
        MockERC20(fromToken).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fromToken).approve(oneInchProxy, amountIn);
        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );
        vm.stopPrank();

        assertEq(IERC20(fromToken).balanceOf(alice), 0);
        assertEq(IERC20(toToken).balanceOf(alice), amountOut);
    }

    function test_swap_slippage_reverts() public {
        MockAggregationRouterV6(router).setRate(0.5e18);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(IAggregatorSwapper.InsufficientAmountOut.selector, 0.5 ether, 1 ether));
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 1 ether, _routerData(amountIn));
    }

    function test_swap_routerRevert_surfacesError() public {
        MockAggregationRouterV6(router).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert();
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_reentrancyGuard() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(
            IAggregatorSwapper.swap,
            (fromToken, toToken, amountIn, 0, _routerData(amountIn))
        );
        MockAggregationRouterV6(router).setReentrantCall(oneInchProxy, reentrantCall);

        vm.expectRevert();
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_partialFill_refundsUnspent() public {
        MockAggregationRouterV6(router).setPartialFillRatio(0.6e18);

        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );

        assertEq(amountOut, 0.6 ether);
        assertEq(IERC20(toToken).balanceOf(address(this)), 0.6 ether);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0.4 ether);
        assertEq(IERC20(fromToken).balanceOf(oneInchProxy), 0);
        assertEq(IERC20(toToken).balanceOf(oneInchProxy), 0);
    }
}
