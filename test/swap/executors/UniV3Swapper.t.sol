// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests UniV3Swapper_v1: UniV3 routing via exactInput, approval cleanup, token transfer
// invariants, PATH_SETTER_ROLE path management, slippage protection, and reentrancy guard.
// Uses the deploy script (Swapper.sol) so the CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockUniV3Router} from "@harbor-swap-test-mocks/MockUniV3Router.sol";

import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract UniV3SwapperTest is BaoTest, Swapper {
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

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));
        midToken = address(new MockERC20("Mid Token", "MID", 18));

        uniRouter = address(new MockUniV3Router());

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

    /// @notice Path configured → swap routes through UniV3 exactInput; toToken arrives at caller.
    function test_swap_usesUniswapV3() public {
        _configurePath();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, amountIn); // MockUniV3Router default rate = 1e18 → 1:1
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

    /// @notice When router output is below minAmountOut the swap reverts (slippage protection).
    function test_swap_slippage_reverts() public {
        _configurePath();
        MockUniV3Router(uniRouter).setRate(0.9e18); // router returns 0.9 ether for 1 ether in
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn);

        vm.expectRevert(); // MockUniV3Router enforces amountOutMinimum → reverts
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 1 ether);
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

    /// @notice A re-entrant call from the router into swap() is blocked by nonReentrant.
    function test_swap_reentrancyGuard() public {
        _configurePath();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, uniV3SwapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fromToken, toToken, amountIn, 0));
        MockUniV3Router(uniRouter).setReentrantCall(uniV3SwapperProxy, reentrantCall);

        vm.expectRevert();
        ISwapExecutor(uniV3SwapperProxy).swap(fromToken, toToken, amountIn, 0);
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

    /// @notice Non-owner reverts; owner call stores path successfully.
    function test_setPath_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, _singleHopPath());

        _configurePath();
        assertGt(UniV3Swapper_v1(uniV3SwapperProxy).paths(fromToken, toToken).length, 0);
    }

    /// @notice Address granted PATH_SETTER_ROLE can call setPath without being owner.
    function test_setPath_calledByPathSetter_succeeds() public {
        UniV3Swapper_v1(uniV3SwapperProxy).grantRoles(
            pathSetter,
            UniV3Swapper_v1(uniV3SwapperProxy).PATH_SETTER_ROLE()
        );

        vm.prank(pathSetter);
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, _singleHopPath());

        assertGt(UniV3Swapper_v1(uniV3SwapperProxy).paths(fromToken, toToken).length, 0);
    }

    /// @notice Address without PATH_SETTER_ROLE or ownership cannot call setPath.
    function test_setPath_calledByStranger_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        UniV3Swapper_v1(uniV3SwapperProxy).setPath(fromToken, toToken, _singleHopPath());
    }
}
