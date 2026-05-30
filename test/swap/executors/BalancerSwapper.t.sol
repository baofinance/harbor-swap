// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests BalancerSwapper_v1: Balancer V2 single-swap routing via the Vault, per-pair
// poolId config, approval cleanup, slippage protection, role gate, and reentrancy guard.
// Uses the deploy script (Swapper.sol) so the CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockBalancerVault} from "@harbor-swap-test-mocks/MockBalancerVault.sol";

import {BalancerSwapper_v1} from "@harbor-swap/executors/BalancerSwapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract BalancerSwapperTest is BaoTest, Swapper {
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
        return address(0);
    }

    // ── Actors ───────────────────────────────────────────────────────
    address alice = makeAddr("alice");
    address routeSetter = makeAddr("routeSetter");

    // ── Tokens ───────────────────────────────────────────────────────
    address fromToken;
    address toToken;

    // ── Infrastructure addresses ─────────────────────────────────────
    address vault;
    address balancerSwapperProxy;

    bytes32 constant POOL_ID = bytes32(uint256(0xb0070001));
    string constant SALT_PREFIX = "test_balancerswapper";

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 18));
        toToken = address(new MockERC20("To Token", "TO", 18));

        vault = address(new MockBalancerVault());

        DeploymentTypes.State memory state = DeploymentTypes.State({
            network: "test",
            saltPrefix: SALT_PREFIX,
            directoryPrefix: "",
            implementations: new DeploymentTypes.ImplementationRecord[](0),
            proxies: new DeploymentTypes.ProxyRecord[](0),
            baoFactory: baoFactory()
        });
        deployBalancerSwapper(state, vault);
        balancerSwapperProxy = _predictAddress("balancerSwapper");
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _configureRoute() internal {
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken, toToken, POOL_ID);
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice Configured pool ID: Vault.swap is invoked; toToken arrives at caller.
    function test_swap_happyPath() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, amountIn, "MockBalancerVault default rate 1:1");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    /// @notice VAULT immutable matches the deploy-wired address.
    function test_vault_immutable_isSet() public view {
        assertEq(BalancerSwapper_v1(balancerSwapperProxy).VAULT(), vault);
    }

    /// @notice No configured route -> NoRouteConfigured.
    function test_swap_noRoute_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(BalancerSwapper_v1.NoRouteConfigured.selector, fromToken, toToken)
        );
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Vault's own limit enforcement reverts when rate is below the slippage floor.
    function test_swap_slippage_reverts() public {
        _configureRoute();
        MockBalancerVault(vault).setRate(0.9e18);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);

        vm.expectRevert(); // Vault rejects below limit
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 1 ether);
    }

    /// @notice Vault allowance is cleared to zero after every swap.
    function test_swap_approvalsCleared() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        assertEq(IERC20(fromToken).allowance(balancerSwapperProxy, vault), 0);
    }

    /// @notice fromToken pulled from msg.sender; toToken delivered to msg.sender.
    function test_swap_tokensTransferred() public {
        _configureRoute();
        uint256 amountIn = 3 ether;
        MockERC20(fromToken).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fromToken).approve(balancerSwapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        vm.stopPrank();

        assertEq(IERC20(fromToken).balanceOf(alice), 0);
        assertEq(IERC20(toToken).balanceOf(alice), amountOut);
    }

    /// @notice Re-entrant call from the Vault is blocked by nonReentrant.
    function test_swap_reentrancyGuard() public {
        _configureRoute();
        uint256 amountIn = 1 ether;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fromToken, toToken, amountIn, 0));
        MockBalancerVault(vault).setReentrantCall(balancerSwapperProxy, reentrantCall);

        vm.expectRevert();
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Route is stored and retrievable; clearing with bytes32(0) removes it.
    function test_setRoute_storeAndClear() public {
        _configureRoute();
        assertEq(BalancerSwapper_v1(balancerSwapperProxy).poolIds(fromToken, toToken), POOL_ID);

        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken, toToken, bytes32(0));
        assertEq(BalancerSwapper_v1(balancerSwapperProxy).poolIds(fromToken, toToken), bytes32(0));
    }

    /// @notice Non-owner / non-role address cannot call setRoute.
    function test_setRoute_calledByStranger_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken, toToken, POOL_ID);
    }

    /// @notice Address granted ROUTE_SETTER_ROLE can call setRoute without owning.
    function test_setRoute_calledByRouteSetter_succeeds() public {
        BalancerSwapper_v1(balancerSwapperProxy).grantRoles(
            routeSetter,
            BalancerSwapper_v1(balancerSwapperProxy).ROUTE_SETTER_ROLE()
        );

        vm.prank(routeSetter);
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken, toToken, POOL_ID);

        assertEq(BalancerSwapper_v1(balancerSwapperProxy).poolIds(fromToken, toToken), POOL_ID);
    }
}
