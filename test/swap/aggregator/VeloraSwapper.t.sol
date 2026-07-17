// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests VeloraSwapper_v1: aggregator adapter calling a fixed router with keeper-supplied
// calldata. Verifies v6.2 selector allowlist, balance-delta slippage, partial-fill refunds,
// approval cleanup, token transfer invariants, and reentrancy guard.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockAugustusV62} from "@harbor-swap-test-mocks/MockAugustusV62.sol";

import {VeloraSwapper_v1} from "@harbor-swap/aggregator/VeloraSwapper_v1.sol";
import {VeloraV62Selectors} from "@harbor-swap/aggregator/VeloraV62Selectors.sol";
import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract VeloraSwapperTest is BaoTest, TokenHolderTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    function _tokenHolderTarget() internal view override returns (address) {
        return veloraProxy;
    }

    function _tokenHolderSweepToken() internal view override returns (address) {
        return fromToken;
    }

    function _tokenHolderNonOwner() internal view override returns (address) {
        return alice;
    }

    address alice = makeAddr("alice");

    address fromToken;
    address toToken;
    address router;
    address veloraProxy;

    string constant SALT_PREFIX = "test_velora";

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));

        router = address(new MockAugustusV62());
        assertEq(MockAugustusV62(router).swapExactAmountInSelector(), VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN);
        assertEq(MockAugustusV62(router).swapExactAmountOutSelector(), VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployVeloraSwapper(state, router);
        veloraProxy = _predictAddress("veloraSwapper");
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    function _swapData(uint256 amountIn) internal view returns (MockAugustusV62.GenericData memory data) {
        data = MockAugustusV62.GenericData({
            srcToken: fromToken,
            destToken: toToken,
            fromAmount: amountIn,
            toAmount: 0,
            quotedAmount: 0,
            metadata: bytes32(0),
            beneficiary: address(0)
        });
    }

    function _routerData(uint256 amountIn) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                MockAugustusV62.swapExactAmountIn,
                (address(0), _swapData(amountIn), 0, hex"", hex"")
            );
    }

    function test_swap_happyPath() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(
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
        assertEq(VeloraSwapper_v1(veloraProxy).ROUTER(), router);
    }

    function test_swap_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));

        assertEq(IERC20(fromToken).allowance(veloraProxy, router), 0);
    }

    function test_swap_sameToken_passthrough() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(fromToken, fromToken, amountIn, amountIn, hex"");

        assertEq(amountOut, amountIn);
        assertEq(IERC20(fromToken).balanceOf(address(this)), amountIn);
    }

    function test_swap_rejectsEmptyCalldata() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        vm.expectRevert(IAggregatorSwapper.RouterCalldataTooShort.selector);
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, hex"");
    }

    function test_swap_rejectsDisallowedSelector() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        bytes memory badData = abi.encodePacked(bytes4(0xdeadbeef), _routerData(amountIn));

        vm.expectRevert(
            abi.encodeWithSelector(IAggregatorSwapper.DisallowedRouterSelector.selector, bytes4(0xdeadbeef))
        );
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, badData);
    }

    function test_swap_acceptsSwapExactAmountInSelector() public view {
        bytes memory data = _routerData(1 ether);
        assertEq(bytes4(data), VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN);
    }

    function test_swap_acceptsSwapExactAmountOutSelector() public view {
        bytes memory data = abi.encodeCall(
            MockAugustusV62.swapExactAmountOut,
            (address(0), _swapData(1 ether), 0, hex"", hex"")
        );
        assertEq(bytes4(data), VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT);
    }

    function test_swap_happyPath_swapExactAmountOut() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        bytes memory data = abi.encodeCall(
            MockAugustusV62.swapExactAmountOut,
            (address(0), _swapData(amountIn), 0, hex"", hex"")
        );

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, data);
        assertEq(amountOut, amountIn);
    }

    function test_swap_tokensTransferred() public {
        uint256 amountIn = 3 ether;
        MockERC20(fromToken).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fromToken).approve(veloraProxy, amountIn);
        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(
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
        MockAugustusV62(router).setRate(0.5e18);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(IAggregatorSwapper.InsufficientAmountOut.selector, 0.5 ether, 1 ether));
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 1 ether, _routerData(amountIn));
    }

    function test_swap_routerRevert_surfacesError() public {
        MockAugustusV62(router).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        vm.expectRevert();
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_reentrancyGuard() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(
            IAggregatorSwapper.swap,
            (fromToken, toToken, amountIn, 0, _routerData(amountIn))
        );
        MockAugustusV62(router).setReentrantCall(veloraProxy, reentrantCall);

        vm.expectRevert();
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_partialFill_refundsUnspent() public {
        MockAugustusV62(router).setPartialFillRatio(0.6e18);

        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );

        assertEq(amountOut, 0.6 ether);
        assertEq(IERC20(toToken).balanceOf(address(this)), 0.6 ether);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0.4 ether);
        assertEq(IERC20(fromToken).balanceOf(veloraProxy), 0);
        assertEq(IERC20(toToken).balanceOf(veloraProxy), 0);
    }
}
