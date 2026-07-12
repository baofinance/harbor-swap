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
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {MockFeeOnTransferERC20} from "@harbor-swap-test-mocks/MockFeeOnTransferERC20.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract OneInchSwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, Swapper {
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
        return oneInchProxy;
    }

    function _tokenHolderSweepToken() internal view override returns (address) {
        return fromToken;
    }

    function _tokenHolderNonOwner() internal view override returns (address) {
        return alice;
    }

    function _swapExecutorTarget() internal view override returns (address) {
        return oneInchProxy;
    }

    function _swapFromToken() internal view override returns (address) {
        return fromToken;
    }

    function _swapToToken() internal view override returns (address) {
        return toToken;
    }

    function _swapCall(
        address fromToken_,
        address toToken_,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal override returns (uint256) {
        return
            IAggregatorSwapper(oneInchProxy).swap(
                fromToken_,
                toToken_,
                amountIn,
                minAmountOut,
                _routerDataFor(fromToken_, toToken_, amountIn)
            );
    }

    function _setVenueRate(uint256 rate) internal override {
        MockAggregationRouterV6(router).setRate(rate);
    }

    function _expectedOut(uint256 amountIn) internal view override returns (uint256) {
        return (amountIn * MockAggregationRouterV6(router).rate()) / 1e18;
    }

    /// @dev The mock router never honours a minimum (1inch's minReturn lives inside opaque
    ///      calldata), so under-delivering is just a rate cut.
    function _setVenueLiar() internal override {
        MockAggregationRouterV6(router).setRate(MockAggregationRouterV6(router).rate() / 2);
    }

    address alice = makeAddr("alice");

    address fromToken;
    address toToken;
    address router;
    address oneInchProxy;

    string constant SALT_PREFIX = "test_oneinch";

    /// @dev Non-unity fixture rate with a DECIMALS GAP baked in: the router mints out-units
    ///      per in-unit ×1e18, and the fixture pair is 6-decimals → 18-decimals (a
    ///      USDC→WETH-like direction, the opposite gap to the Curve fixture). 1e6 in-units ≈
    ///      0.000447e18 out-wei, so the rate is 0.000447e18 × 1e12 = 0.000447e30. No
    ///      assertion can pass by an `amountOut == amountIn` tautology or by assuming equal
    ///      decimals.
    uint256 constant ROUTER_RATE = 0.000447e30;

    /// @dev 1000 whole units of the 6-decimals fromToken.
    uint256 constant AMOUNT_IN = 1_000e6;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 6));
        toToken = address(new MockERC20("To Token", "TO", 18));

        router = address(new MockAggregationRouterV6());
        assertEq(MockAggregationRouterV6(router).swapSelector(), OneInchV6Selectors.SWAP);
        MockAggregationRouterV6(router).setRate(ROUTER_RATE);

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

    /// @notice `_routerData` for an arbitrary token pair (the member-field version covers the
    ///         default pair): v6 `swap` calldata whose mock fill path moves `fromToken_` to
    ///         `toToken_`.
    function _routerDataFor(
        address fromToken_,
        address toToken_,
        uint256 amountIn
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                MockAggregationRouterV6.swap,
                (
                    address(0),
                    MockAggregationRouterV6.SwapDescription({
                        srcToken: fromToken_,
                        dstToken: toToken_,
                        srcReceiver: address(0),
                        dstReceiver: address(0),
                        amount: amountIn,
                        minReturnAmount: 0,
                        flags: 0
                    }),
                    abi.encode(fromToken_, toToken_, amountIn)
                )
            );
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
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );

        assertEq(amountOut, _expectedOut(amountIn), "router-rate-scaled output");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    function test_router_immutable_isSet() public view {
        assertEq(OneInchSwapper_v1(oneInchProxy).ROUTER(), router);
    }

    function test_swap_approvalsCleared() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));

        assertEq(IERC20(fromToken).allowance(oneInchProxy, router), 0);
    }

    function test_swap_rejectsEmptyCalldata() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert(IAggregatorSwapper.RouterCalldataTooShort.selector);
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, hex"");
    }

    function test_swap_rejectsDisallowedSelector() public {
        uint256 amountIn = AMOUNT_IN;
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
        uint256 amountIn = 3 * AMOUNT_IN;
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

    function test_swap_routerRevert_surfacesError() public {
        MockAggregationRouterV6(router).setShouldRevert(true);
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert();
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_reentrancyGuard() public {
        uint256 amountIn = AMOUNT_IN;
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

        uint256 amountIn = AMOUNT_IN;
        uint256 spent = (amountIn * 0.6e18) / 1e18;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );

        assertEq(amountOut, _expectedOut(spent), "output scaled from the spent portion");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), amountIn - spent, "unspent portion refunded");
        assertEq(IERC20(fromToken).balanceOf(oneInchProxy), 0);
        assertEq(IERC20(toToken).balanceOf(oneInchProxy), 0);
    }

    /// @notice A fee-on-transfer fromToken delivers less than amountIn to the adapter and is
    ///         rejected up front with UnexpectedAmountIn (exact expected/received amounts) —
    ///         never an arithmetic panic or a wrapped venue error.
    function test_swap_feeOnTransferFromToken_reverts() public {
        uint256 feeBps = 100; // 1%
        address fot = address(new MockFeeOnTransferERC20("Fee Token", "FEE", feeBps));
        uint256 amountIn = 1 ether;
        MockFeeOnTransferERC20(fot).mint(address(this), amountIn);
        IERC20(fot).approve(oneInchProxy, amountIn);

        uint256 received = amountIn - (amountIn * feeBps) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.UnexpectedAmountIn.selector, amountIn, received));
        IAggregatorSwapper(oneInchProxy).swap(fot, toToken, amountIn, 0, _routerDataFor(fot, toToken, amountIn));
    }
}
