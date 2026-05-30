// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests OneInchSwapper_v1: aggregator adapter calling a fixed router with keeper-supplied
// calldata. Verifies balance-delta slippage, partial-fill refunds, approval cleanup, token
// transfer invariants, and reentrancy guard. Uses the deploy script (Swapper.sol) so the
// CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockRawRouter} from "@harbor-swap-test-mocks/MockRawRouter.sol";

import {OneInchSwapper_v1} from "@harbor-swap/aggregator/OneInchSwapper_v1.sol";
import {IAggregatorSwapper} from "@harbor-swap/aggregator/IAggregatorSwapper.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

/// @notice Mock router that partially fills: it pulls only `partialFillRatio` of amountIn
///         and mints the corresponding output, leaving the rest in the adapter as refund.
contract MockPartialFillRouter {
    uint256 public partialFillRatio = 1e18; // 1e18 = full fill (default)
    uint256 public rate = 1e18; // 1:1

    function setPartialFillRatio(uint256 ratio_) external {
        partialFillRatio = ratio_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    /// @notice Encode as `routerData` in OneInchSwapper.swap(..., data).
    function swap(address fromToken, address toToken, uint256 amountIn) external returns (uint256 amountOut) {
        uint256 spent = (amountIn * partialFillRatio) / 1e18;
        IERC20(fromToken).transferFrom(msg.sender, address(this), spent);
        amountOut = (spent * rate) / 1e18;
        MockERC20(toToken).mint(msg.sender, amountOut);
    }
}

contract OneInchSwapperTest is BaoTest, Swapper {
    // ── FactoryDeployer abstracts ─────────────────────────────────────
    function owner() public view override returns (address) {
        return address(this);
    }
    function treasury() public view override returns (address) {
        return address(this);
    }
    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }
    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0); // UniV3 executor not used in OneInchSwapper tests
    }

    // ── Actors ───────────────────────────────────────────────────────
    address alice = makeAddr("alice");

    // ── Token addresses ──────────────────────────────────────────────
    address fromToken;
    address toToken;

    // ── Infrastructure addresses ─────────────────────────────────────
    address router;
    address oneInchProxy;

    string constant SALT_PREFIX = "test_oneinch";

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));

        router = address(new MockRawRouter());

        DeploymentTypes.State memory state = DeploymentTypes.State({
            network: "test",
            saltPrefix: SALT_PREFIX,
            directoryPrefix: "",
            implementations: new DeploymentTypes.ImplementationRecord[](0),
            proxies: new DeploymentTypes.ProxyRecord[](0),
            baoFactory: baoFactory()
        });
        deployOneInchSwapper(state, router);
        oneInchProxy = _predictAddress("oneInchSwapper");
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    function _routerData(uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeCall(MockRawRouter.swap, (fromToken, toToken, amountIn));
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice Happy path: caller pre-approves adapter, calls swap, receives toToken.
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

        assertEq(amountOut, amountIn, "MockRawRouter default rate 1:1");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    /// @notice ROUTER immutable matches what the deploy script wired up.
    function test_router_immutable_isSet() public view {
        assertEq(OneInchSwapper_v1(oneInchProxy).ROUTER(), router);
    }

    /// @notice Router approval is reset to zero after every swap.
    function test_swap_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));

        assertEq(IERC20(fromToken).allowance(oneInchProxy, router), 0);
    }

    /// @notice Same-token swap is a pass-through; no router call, exact amount delivered.
    function test_swap_sameToken_passthrough() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        // routerData is intentionally junk — pass-through must not call the router.
        uint256 amountOut = IAggregatorSwapper(oneInchProxy).swap(
            fromToken,
            fromToken,
            amountIn,
            amountIn,
            hex""
        );

        assertEq(amountOut, amountIn);
        assertEq(IERC20(fromToken).balanceOf(address(this)), amountIn);
    }

    /// @notice fromToken pulled from msg.sender; toToken delivered to msg.sender.
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

    /// @notice Adapter rejects when post-call balance delta is below minAmountOut.
    function test_swap_slippage_reverts() public {
        MockRawRouter(router).setRate(0.5e18); // router returns 0.5 ether for 1 ether in
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(IAggregatorSwapper.InsufficientAmountOut.selector, 0.5 ether, 1 ether)
        );
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 1 ether, _routerData(amountIn));
    }

    /// @notice Router revert is surfaced with the original revert data.
    function test_swap_routerRevert_surfacesError() public {
        MockRawRouter(router).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn);

        vm.expectRevert(); // RouterCallFailed wraps the inner revert data
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    /// @notice Re-entrant call from the router into swap() is blocked by nonReentrant.
    function test_swap_reentrancyGuard() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, oneInchProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(
            IAggregatorSwapper.swap,
            (fromToken, toToken, amountIn, 0, _routerData(amountIn))
        );
        MockRawRouter(router).setReentrantCall(oneInchProxy, reentrantCall);

        vm.expectRevert();
        IAggregatorSwapper(oneInchProxy).swap(fromToken, toToken, amountIn, 0, _routerData(amountIn));
    }

    /// @notice Partial fill: router pulls only a fraction of amountIn; adapter refunds
    ///         the unspent input back to the caller and forwards the smaller output.
    function test_swap_partialFill_refundsUnspent() public {
        address partialRouter = address(new MockPartialFillRouter());

        DeploymentTypes.State memory state2 = DeploymentTypes.State({
            network: "test",
            saltPrefix: "test_oneinch_partial",
            directoryPrefix: "",
            implementations: new DeploymentTypes.ImplementationRecord[](0),
            proxies: new DeploymentTypes.ProxyRecord[](0),
            baoFactory: baoFactory()
        });
        _setSaltPrefix("test_oneinch_partial");
        deployOneInchSwapper(state2, partialRouter);
        address partialProxy = _predictAddress("oneInchSwapper");

        MockPartialFillRouter(partialRouter).setPartialFillRatio(0.6e18); // 60% fill

        uint256 amountIn = 1 ether;
        MockERC20(fromToken).mint(address(this), amountIn);
        IERC20(fromToken).approve(partialProxy, amountIn);

        bytes memory data = abi.encodeCall(MockPartialFillRouter.swap, (fromToken, toToken, amountIn));
        uint256 amountOut = IAggregatorSwapper(partialProxy).swap(fromToken, toToken, amountIn, 0, data);

        // Router pulled 0.6 ether, minted 0.6 ether. Adapter refunded 0.4 ether unspent.
        assertEq(amountOut, 0.6 ether, "amountOut matches actually-filled portion");
        assertEq(IERC20(toToken).balanceOf(address(this)), 0.6 ether);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0.4 ether, "unspent input refunded");
        // Adapter must not retain any balance after the swap.
        assertEq(IERC20(fromToken).balanceOf(partialProxy), 0);
        assertEq(IERC20(toToken).balanceOf(partialProxy), 0);
    }
}
