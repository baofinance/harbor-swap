// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests UniV3Swapper_v1: UniV3 routing via exactInput, approval cleanup, token transfer
// invariants, PATH_SETTER_ROLE path management, slippage protection, and reentrancy guard —
// plus the shared swap-envelope, TokenHolder and UUPS behaviour suites. Uses the deploy
// script (Swapper.sol) so the CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockUniV3Router} from "@harbor-swap-test-mocks/MockUniV3Router.sol";
import {MockFeeOnTransferERC20} from "@harbor-swap-test-mocks/MockFeeOnTransferERC20.sol";

import {IOwnable} from "@bao/interfaces/IOwnable.sol";
import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {UUPSOwnableTestBase} from "@bao-test/helpers/UUPSOwnableTestBase.t.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract UniV3SwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, UUPSOwnableTestBase, Swapper {
    // ── FactoryDeployer abstracts ─────────────────────────────────────
    function owner() public view override returns (address) {
        return address(this);
    }
    function treasury() public view override returns (address) {
        return address(this);
    }
    function _uniV3RouterAddress() internal view override returns (address) {
        return uniRouter;
    }

    // ── TokenHolder behaviour hooks ───────────────────────────────────
    function _tokenHolderTarget() internal view override returns (address) {
        return uniV3SwapperProxy;
    }
    function _tokenHolderSweepToken() internal view override returns (address) {
        return fromToken;
    }
    function _tokenHolderNonOwner() internal view override returns (address) {
        return alice;
    }

    // ── SwapExecutor behaviour hooks ──────────────────────────────────
    function _swapExecutorTarget() internal view override returns (address) {
        return uniV3SwapperProxy;
    }
    function _swapFromToken() internal view override returns (address) {
        return fromToken;
    }
    function _swapToToken() internal view override returns (address) {
        return toToken;
    }
    function _prepareSwapPair(address fromToken_, address toToken_) internal override {
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken_, toToken_, abi.encodePacked(fromToken_, FEE, toToken_));
    }
    function _swapCall(
        address fromToken_,
        address toToken_,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal override returns (uint256) {
        return ISwapExecutor(uniV3SwapperProxy).swap(fromToken_, toToken_, amountIn, minAmountOut);
    }
    function _setVenueRate(uint256 rate) internal override {
        MockUniV3Router(uniRouter).setRate(rate);
    }
    function _expectedOut(uint256 amountIn) internal view override returns (uint256) {
        return (amountIn * MockUniV3Router(uniRouter).rate()) / 1e18;
    }
    function _setVenueLiar() internal override {
        MockUniV3Router(uniRouter).setHonourMin(false);
        MockUniV3Router(uniRouter).setRate(MockUniV3Router(uniRouter).rate() / 2);
    }

    // ── UUPS behaviour hooks ──────────────────────────────────────────
    function _uupsProxyTarget() internal view override returns (address) {
        return uniV3SwapperProxy;
    }
    function _uupsNonOwner() internal view override returns (address) {
        return alice;
    }
    function _uupsCallInitialize(address target) internal override {
        UniV3Swapper_v1(target).initialize(address(1), address(2));
    }

    // ── Actors ───────────────────────────────────────────────────────
    address alice = makeAddr("alice");
    address pathSetter = makeAddr("pathSetter");

    // ── Token addresses ──────────────────────────────────────────────
    address fromToken;
    address toToken;
    address midToken;

    // ── Infrastructure addresses ─────────────────────────────────────
    address uniRouter;
    address uniV3SwapperProxy;

    uint24 constant FEE = 3000;
    string constant SALT_PREFIX = "test_univ3swapper";

    /// @dev Non-unity fixture rate with a DECIMALS GAP baked in: the router mints out-units
    ///      per in-unit ×1e18, and the fixture pair is 18-decimals → 6-decimals (a
    ///      WETH→USDC-like direction, output-truncating). 1e18 in-units at $2237 →
    ///      2237e6 out-units, so the rate is 2237e6.
    uint256 constant UNIV3_RATE = 2237e6;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 6));
        midToken = address(new MockERC20("Mid Token", "MID", 18));

        uniRouter = address(new MockUniV3Router());
        MockUniV3Router(uniRouter).setRate(UNIV3_RATE);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployUniV3Swapper(state, uniRouter);
        uniV3SwapperProxy = _predictAddress("uniV3Swapper");
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _singleHopPath() internal view returns (bytes memory) {
        return abi.encodePacked(fromToken, FEE, toToken);
    }

    function _multiHopPath() internal view returns (bytes memory) {
        return abi.encodePacked(fromToken, FEE, midToken, FEE, toToken);
    }

    function _configurePath() internal {
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, _singleHopPath());
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice Path configured → swap routes through UniV3 exactInput; the rate-scaled
    ///         toToken output arrives at the caller.
    function test_swap_usesUniswapV3() public {
        _configurePath();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, _expectedOut(amountIn), "router-rate-scaled output");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    /// @notice No path set → reverts with NoPathConfigured.
    function test_swap_noPath_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(UniV3Swapper_v1.NoPathConfigured.selector, fromToken, toToken));
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice The router's own amountOutMinimum enforcement reverts when minAmountOut
    ///         exceeds the router's output (typed call, so the router error bubbles
    ///         unwrapped — the real SwapRouter reverts "Too little received").
    function test_swap_slippage_reverts() public {
        _configurePath();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);
        // Hoisted: an argument sub-expression making an external call would steal the
        // expectRevert binding.
        uint256 rateTooHigh = _expectedRatePerUnitIn() + 1;

        vm.expectRevert(bytes("Too little received"));
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, rateTooHigh);
    }

    /// @notice A forced router revert bubbles unwrapped (typed call — no wrapper error).
    function test_swap_routerRevert_surfacesError() public {
        _configurePath();
        MockUniV3Router(uniRouter).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);

        vm.expectRevert(bytes("MockUniV3Router: forced revert"));
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Router allowance is cleared to zero after every swap.
    function test_swap_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _configurePath();
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);
        assertEq(IERC20(fromToken).allowance(uniV3SwapperProxy, uniRouter), 0);
    }

    /// @notice fromToken is pulled from msg.sender; toToken is delivered to msg.sender.
    function test_swap_tokensTransferred() public {
        _configurePath();
        uint256 amountIn = 3 ether;
        MockERC20(fromToken).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fromToken).approve(uniV3SwapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);
        vm.stopPrank();

        assertEq(IERC20(fromToken).balanceOf(alice), 0);
        assertEq(IERC20(toToken).balanceOf(alice), amountOut);
    }

    /// @notice A re-entrant call from the router into swap() is blocked by nonReentrant; the
    ///         mock bubbles the guard's error unchanged and the typed call re-bubbles it.
    function test_swap_reentrancyGuard() public {
        _configurePath();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fromToken, toToken, amountIn, 0));
        MockUniV3Router(uniRouter).setReentrantCall(uniV3SwapperProxy, reentrantCall);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice A fee-on-transfer fromToken delivers less than amountIn to the executor and is
    ///         rejected up front with UnexpectedAmountIn (exact expected/received amounts).
    function test_swap_feeOnTransferFromToken_reverts() public {
        uint256 feeBps = 100; // 1%
        address fot = address(new MockFeeOnTransferERC20("Fee Token", "FEE", feeBps));
        uint256 amountIn = 1 ether;
        MockFeeOnTransferERC20(fot).mint(address(this), amountIn);
        IERC20(fot).approve(uniV3SwapperProxy, amountIn);
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fot, toToken, abi.encodePacked(fot, FEE, toToken));

        uint256 received = amountIn - (amountIn * feeBps) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.UnexpectedAmountIn.selector, amountIn, received));
        ISwapExecutor(uniV3SwapperProxy).swap(fot, toToken, amountIn, 0);
    }

    /// @notice Single-hop path (43 bytes) is stored and retrievable unchanged.
    function test_setPath_singleHop() public {
        bytes memory path = _singleHopPath();
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, path);

        bytes memory stored = UniV3Swapper_v1(uniV3SwapperProxy).paths(fromToken, toToken);
        assertEq(stored.length, 43);
        assertEq(keccak256(stored), keccak256(path));
    }

    /// @notice setPath emits PathSet for off-chain indexing.
    function test_setPath_emitsPathSet() public {
        bytes memory path = _singleHopPath();
        vm.expectEmit(true, true, false, true);
        emit UniV3Swapper_v1.PathSet(fromToken, toToken, path);
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, path);
    }

    /// @notice Multi-hop path (66 bytes) is stored and retrievable unchanged.
    function test_setPath_multiHop() public {
        bytes memory path = _multiHopPath();
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, path);

        bytes memory stored = UniV3Swapper_v1(uniV3SwapperProxy).paths(fromToken, toToken);
        assertEq(stored.length, 66);
        assertEq(keccak256(stored), keccak256(path));
    }

    /// @notice Address granted PATH_SETTER_ROLE can call setPath without being owner.
    function test_setPath_calledByPathSetter_succeeds() public {
        UniV3Swapper_v1(uniV3SwapperProxy).grantRoles(
            pathSetter,
            UniV3Swapper_v1(uniV3SwapperProxy).PATH_SETTER_ROLE()
        );

        vm.startPrank(pathSetter);
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, _singleHopPath());
        vm.stopPrank();

        assertGt(UniV3Swapper_v1(uniV3SwapperProxy).paths(fromToken, toToken).length, 0);
    }

    /// @notice Address without PATH_SETTER_ROLE or ownership cannot call setPath.
    function test_setPath_calledByStranger_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(IOwnable.Unauthorized.selector);
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, _singleHopPath());
        vm.stopPrank();
    }
}
