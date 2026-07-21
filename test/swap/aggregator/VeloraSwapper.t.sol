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

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Token} from "@bao/Token.sol";
import {VeloraSwapper_v1} from "@harbor-swap/aggregator/VeloraSwapper_v1.sol";
import {VeloraV62Selectors} from "@harbor-swap/aggregator/VeloraV62Selectors.sol";
import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {UUPSOwnableTestBase} from "@bao-test/helpers/UUPSOwnableTestBase.t.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {MockFeeOnTransferERC20} from "@harbor-swap-test-mocks/MockFeeOnTransferERC20.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract VeloraSwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, UUPSOwnableTestBase, Swapper {
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

    function _swapExecutorTarget() internal view override returns (address) {
        return veloraProxy;
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
            IAggregatorSwapper(veloraProxy).swap(
                fromToken_,
                toToken_,
                amountIn,
                minAmountOut,
                _routerDataFor(fromToken_, toToken_, amountIn)
            );
    }

    function _setVenueRate(uint256 rate) internal override {
        MockAugustusV62(router).setRate(rate);
    }

    function _uupsProxyTarget() internal view override returns (address) {
        return veloraProxy;
    }

    function _uupsNonOwner() internal view override returns (address) {
        return alice;
    }

    function _uupsCallInitialize(address target) internal override {
        VeloraSwapper_v1(target).initialize(address(1), address(2));
    }

    function _expectedOut(uint256 amountIn) internal view override returns (uint256) {
        return (amountIn * MockAugustusV62(router).rate()) / 1e18;
    }

    /// @dev The mock router never honours a minimum (Velora's bound lives inside opaque
    ///      calldata), so under-delivering is just a rate cut.
    function _setVenueLiar() internal override {
        MockAugustusV62(router).setRate(MockAugustusV62(router).rate() / 2);
    }

    address alice = makeAddr("alice");

    address fromToken;
    address toToken;
    address router;
    address veloraProxy;

    string constant SALT_PREFIX = "test_velora";

    /// @dev Non-unity fixture rate with a DECIMALS GAP baked in: the router mints out-units
    ///      per in-unit ×1e18, and the fixture pair is 6-decimals → 18-decimals (a
    ///      USDC→WETH-like direction). No assertion can pass by an `amountOut == amountIn`
    ///      tautology or by assuming equal decimals.
    uint256 constant ROUTER_RATE = 0.000447e30;

    /// @dev 1000 whole units of the 6-decimals fromToken.
    uint256 constant AMOUNT_IN = 1_000e6;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 6));
        toToken = address(new MockERC20("To Token", "TO", 18));

        router = address(new MockAugustusV62());
        assertEq(MockAugustusV62(router).swapExactAmountInSelector(), VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN);
        assertEq(MockAugustusV62(router).swapExactAmountOutSelector(), VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT);
        MockAugustusV62(router).setRate(ROUTER_RATE);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployVeloraSwapper(state, router);
        veloraProxy = _predictAddress("veloraSwapper");
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    function _swapData(
        address fromToken_,
        address toToken_,
        uint256 amountIn
    ) internal pure returns (MockAugustusV62.GenericData memory data) {
        data = MockAugustusV62.GenericData({
            srcToken: fromToken_,
            destToken: toToken_,
            fromAmount: amountIn,
            toAmount: 0,
            quotedAmount: 0,
            metadata: bytes32(0),
            beneficiary: address(0)
        });
    }

    function _routerDataFor(
        address fromToken_,
        address toToken_,
        uint256 amountIn
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                MockAugustusV62.swapExactAmountIn,
                (address(0), _swapData(fromToken_, toToken_, amountIn), 0, hex"", hex"")
            );
    }

    function _routerData(uint256 amountIn) internal view returns (bytes memory) {
        return _routerDataFor(fromToken, toToken, amountIn);
    }

    function test_swap_happyPath() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn);
        uint256 expected = _expectedOut(amountIn);

        vm.expectEmit(true, true, true, true);
        emit IAggregatorSwapper.AggregatorSwap(address(this), fromToken, toToken, amountIn, expected, 0);

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(
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
        assertEq(VeloraSwapper_v1(veloraProxy).ROUTER(), router);
    }

    function test_swap_approvalsCleared() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));

        assertEq(IERC20(fromToken).allowance(veloraProxy, router), 0);
    }

    function test_swap_rejectsEmptyCalldata() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        vm.expectRevert(IAggregatorSwapper.RouterCalldataTooShort.selector);
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, hex"");
    }

    function test_swap_rejectsDisallowedSelector() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        bytes memory badData = abi.encodePacked(bytes4(0xdeadbeef), _routerData(amountIn));

        vm.expectRevert(
            abi.encodeWithSelector(IAggregatorSwapper.DisallowedRouterSelector.selector, bytes4(0xdeadbeef))
        );
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, badData);
    }

    function test_swap_acceptsSwapExactAmountInSelector() public view {
        bytes memory data = _routerData(AMOUNT_IN);
        assertEq(bytes4(data), VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN);
    }

    function test_swap_acceptsSwapExactAmountOutSelector() public view {
        bytes memory data = abi.encodeCall(
            MockAugustusV62.swapExactAmountOut,
            (address(0), _swapData(fromToken, toToken, AMOUNT_IN), 0, hex"", hex"")
        );
        assertEq(bytes4(data), VeloraV62Selectors.SWAP_EXACT_AMOUNT_OUT);
    }

    function test_swap_happyPath_swapExactAmountOut() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        bytes memory data = abi.encodeCall(
            MockAugustusV62.swapExactAmountOut,
            (address(0), _swapData(fromToken, toToken, amountIn), 0, hex"", hex"")
        );

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, data);
        assertEq(amountOut, _expectedOut(amountIn));
    }

    function test_swap_tokensTransferred() public {
        uint256 amountIn = 3 * AMOUNT_IN;
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

    function test_swap_routerRevert_surfacesError() public {
        MockAugustusV62(router).setShouldRevert(true);
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAggregatorSwapper.RouterCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "MockAugustusV62: forced revert")
            )
        );
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_reentrancyGuard() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, veloraProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(
            IAggregatorSwapper.swap,
            (fromToken, toToken, amountIn, 0, _routerData(amountIn))
        );
        MockAugustusV62(router).setReentrantCall(veloraProxy, reentrantCall);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAggregatorSwapper.RouterCallFailed.selector,
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            )
        );
        IAggregatorSwapper(veloraProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    function test_swap_partialFill_refundsUnspent() public {
        MockAugustusV62(router).setPartialFillRatio(0.6e18);

        uint256 amountIn = AMOUNT_IN;
        uint256 spent = (amountIn * 0.6e18) / 1e18;
        _mintAndApprove(fromToken, veloraProxy, amountIn);
        uint256 expected = _expectedOut(spent);

        vm.expectEmit(true, true, true, true);
        emit IAggregatorSwapper.AggregatorSwap(address(this), fromToken, toToken, amountIn, expected, amountIn - spent);

        uint256 amountOut = IAggregatorSwapper(veloraProxy).swap(
            fromToken,
            toToken,
            amountIn,
            0,
            _routerData(amountIn)
        );

        assertEq(amountOut, _expectedOut(spent), "output scaled from the spent portion");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), amountIn - spent, "unspent portion refunded");
        assertEq(IERC20(fromToken).balanceOf(veloraProxy), 0);
        assertEq(IERC20(toToken).balanceOf(veloraProxy), 0);
    }

    /// @notice The constructor rejects a router address with no code.
    function test_constructor_nonContractRouter_reverts() public {
        address eoa = makeAddr("eoaRouter");
        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, eoa));
        new VeloraSwapper_v1(eoa);
    }

    /// @notice A fee-on-transfer fromToken delivers less than amountIn to the adapter and is
    ///         rejected up front with UnexpectedAmountIn (exact expected/received amounts) —
    ///         never an arithmetic panic or a wrapped venue error.
    function test_swap_feeOnTransferFromToken_reverts() public {
        uint256 feeBps = 100; // 1%
        address fot = address(new MockFeeOnTransferERC20("Fee Token", "FEE", feeBps));
        uint256 amountIn = 1 ether;
        MockFeeOnTransferERC20(fot).mint(address(this), amountIn);
        IERC20(fot).approve(veloraProxy, amountIn);

        uint256 received = amountIn - (amountIn * feeBps) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.UnexpectedAmountIn.selector, amountIn, received));
        IAggregatorSwapper(veloraProxy).swap(fot, toToken, amountIn, 0, _routerDataFor(fot, toToken, amountIn));
    }
}
