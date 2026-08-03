// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests Swapper_v1: pure registry that maps (from, to) → {swapExecutor, routeCostRatio}.
// Verifies setRoute storage, getRoutesFrom batch queries, and access control.
// Uses the deploy script (Swapper.sol) so the CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {Swapper_v1} from "@harbor-swap/Swapper_v1.sol";
import {ISwapper} from "@harbor-swap/interfaces/ISwapper.sol";
import {ISwapperConfig} from "@harbor-swap/interfaces/ISwapperConfig.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract SwapperTest is BaoTest, Swapper {
    // ── FactoryDeployer abstracts ─────────────────────────────────────
    function owner() public view override returns (address) {
        return address(this);
    }
    function treasury() public view override returns (address) {
        return address(this);
    }
    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0); // UniV3 executor not used in Swapper registry tests
    }

    // ── Actors ───────────────────────────────────────────────────────
    address alice = makeAddr("alice");
    address routeSetter = makeAddr("routeSetter");

    // ── Token addresses ──────────────────────────────────────────────
    address fromToken;
    address toToken;
    address midToken;

    // ── Mock swap executor ───────────────────────────────────────────
    address mockExecutor;

    // ── Infrastructure addresses ─────────────────────────────────────
    address swapperProxy;

    uint256 constant ROUTE_COST_RATIO = 3e15; // 0.3% as a 1e18-scaled ratio
    string constant SALT_PREFIX = "test_swapper";

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));
        midToken = address(new MockERC20("Mid Token", "MID", 18));

        mockExecutor = makeAddr("mockExecutor");

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deploySwapper(state);
        swapperProxy = _predictAddress("swapper");
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _configureRoute() internal {
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, mockExecutor, ROUTE_COST_RATIO);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice setRoute stores executor and routeCostRatio; public mappings reflect both.
    function test_setRoute_storesExecutorAndRouteCost() public {
        _configureRoute();
        assertEq(Swapper_v1(swapperProxy).swapExecutors(fromToken, toToken), mockExecutor);
        assertEq(Swapper_v1(swapperProxy).routeCostRatios(fromToken, toToken), ROUTE_COST_RATIO);
    }

    /// @notice setRoute(from, to, address(0), 0) clears the route; getRoutesFrom reports unavailable.
    function test_setRoute_zeroAddress_clearsRoute() public {
        _configureRoute();
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, address(0), 0);

        address[] memory targets = new address[](1);
        targets[0] = toToken;
        ISwapper.RouteInfo[] memory infos = ISwapper(swapperProxy).getRoutesFrom(fromToken, targets);
        assertFalse(infos[0].available, "cleared route should be unavailable");
        assertEq(infos[0].swapExecutor, address(0), "cleared route executor should be address(0)");
    }

    /// @notice Non-owner reverts; owner call stores route successfully.
    function test_setRoute_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, mockExecutor, ROUTE_COST_RATIO);

        _configureRoute();
        assertEq(Swapper_v1(swapperProxy).swapExecutors(fromToken, toToken), mockExecutor);
    }

    /// @notice Address granted ROUTE_SETTER_ROLE can call setRoute without being owner.
    function test_setRoute_calledByRouteSetter_succeeds() public {
        Swapper_v1(swapperProxy).grantRoles(routeSetter, Swapper_v1(swapperProxy).ROUTE_SETTER_ROLE());

        vm.prank(routeSetter);
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, mockExecutor, ROUTE_COST_RATIO);

        assertEq(Swapper_v1(swapperProxy).swapExecutors(fromToken, toToken), mockExecutor);
    }

    /// @notice Address without ROUTE_SETTER_ROLE or ownership reverts.
    function test_setRoute_calledByStranger_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, mockExecutor, ROUTE_COST_RATIO);
    }

    /// @notice getRoutesFrom returns the swap executor address for a configured pair.
    function test_getRoutesFrom_returnsSwapExecutor() public {
        _configureRoute();
        address[] memory targets = new address[](1);
        targets[0] = toToken;
        ISwapper.RouteInfo[] memory infos = ISwapper(swapperProxy).getRoutesFrom(fromToken, targets);
        assertEq(infos[0].swapExecutor, mockExecutor, "swapExecutor should match configured address");
    }

    /// @notice getRoutesFrom returns available=true for configured pairs, false for unconfigured.
    function test_getRoutesFrom_returnsAvailability() public {
        _configureRoute(); // sets fromToken → toToken

        address[] memory targets = new address[](2);
        targets[0] = toToken;
        targets[1] = midToken; // not configured

        ISwapper.RouteInfo[] memory infos = ISwapper(swapperProxy).getRoutesFrom(fromToken, targets);

        assertEq(infos.length, 2);
        assertTrue(infos[0].available, "configured pair: available=true");
        assertEq(infos[0].target, toToken);
        assertFalse(infos[1].available, "unconfigured pair: available=false");
        assertEq(infos[1].target, midToken);
        assertEq(infos[1].swapExecutor, address(0), "unconfigured pair: executor=address(0)");
    }

    /// @notice getRoutesFrom returns the routeCostRatio stored via setRoute.
    function test_getRoutesFrom_returnsCorrectRouteCost() public {
        uint256 customRatio = 1e16; // 1%
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, mockExecutor, customRatio);

        address[] memory targets = new address[](1);
        targets[0] = toToken;

        ISwapper.RouteInfo[] memory infos = ISwapper(swapperProxy).getRoutesFrom(fromToken, targets);

        assertEq(infos[0].routeCostRatio, customRatio, "routeCostRatio matches stored value");
    }

    /// @notice getRoutesFrom with an empty targets array returns an empty result without reverting.
    function test_getRoutesFrom_emptyTargets() public view {
        address[] memory targets = new address[](0);
        ISwapper.RouteInfo[] memory infos = ISwapper(swapperProxy).getRoutesFrom(fromToken, targets);
        assertEq(infos.length, 0, "empty targets: empty result");
    }

    /// @notice getRoute returns the same RouteInfo as a single-element getRoutesFrom batch.
    function test_getRoute_matchesGetRoutesFrom() public {
        _configureRoute();
        ISwapper.RouteInfo memory single = ISwapper(swapperProxy).getRoute(fromToken, toToken);
        address[] memory targets = new address[](1);
        targets[0] = toToken;
        ISwapper.RouteInfo[] memory batch = ISwapper(swapperProxy).getRoutesFrom(fromToken, targets);
        assertEq(single.target, batch[0].target);
        assertEq(single.available, batch[0].available);
        assertEq(single.routeCostRatio, batch[0].routeCostRatio);
        assertEq(single.swapExecutor, batch[0].swapExecutor);
    }

    /// @notice setRoute emits RouteUpdated for off-chain indexing.
    function test_setRoute_emitsRouteUpdated() public {
        vm.expectEmit(true, true, true, true);
        emit ISwapperConfig.RouteUpdated(fromToken, toToken, mockExecutor, ROUTE_COST_RATIO);
        Swapper_v1(swapperProxy).setRoute(fromToken, toToken, mockExecutor, ROUTE_COST_RATIO);
    }
}
