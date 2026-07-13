// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests BalancerSwapper_v1: Balancer V2 single-swap routing via the Vault, per-pair
// poolId config, approval cleanup, slippage protection, role gate, and reentrancy guard —
// plus the shared swap-envelope, TokenHolder and UUPS behaviour suites. Uses the deploy
// script (Swapper.sol) so the CREATE3 proxy path is exercised.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockBalancerVault} from "@harbor-swap-test-mocks/MockBalancerVault.sol";
import {MockFeeOnTransferERC20} from "@harbor-swap-test-mocks/MockFeeOnTransferERC20.sol";

import {IOwnable} from "@bao/interfaces/IOwnable.sol";
import {BalancerSwapper_v1} from "@harbor-swap/executors/BalancerSwapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {UUPSOwnableTestBase} from "@bao-test/helpers/UUPSOwnableTestBase.t.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract BalancerSwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, UUPSOwnableTestBase, Swapper {
    // ── FactoryDeployer abstracts ─────────────────────────────────────
    function owner() public view override returns (address) {
        return address(this);
    }
    function treasury() public view override returns (address) {
        return address(this);
    }
    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    // ── TokenHolder behaviour hooks ───────────────────────────────────
    function _tokenHolderTarget() internal view override returns (address) {
        return balancerSwapperProxy;
    }
    function _tokenHolderSweepToken() internal view override returns (address) {
        return fromToken;
    }
    function _tokenHolderNonOwner() internal view override returns (address) {
        return alice;
    }

    // ── SwapExecutor behaviour hooks ──────────────────────────────────
    function _swapExecutorTarget() internal view override returns (address) {
        return balancerSwapperProxy;
    }
    function _swapFromToken() internal view override returns (address) {
        return fromToken;
    }
    function _swapToToken() internal view override returns (address) {
        return toToken;
    }
    function _prepareSwapPair(address fromToken_, address toToken_) internal override {
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken_, toToken_, POOL_ID);
    }
    function _swapCall(
        address fromToken_,
        address toToken_,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal override returns (uint256) {
        return ISwapExecutor(balancerSwapperProxy).swap(fromToken_, toToken_, amountIn, minAmountOut);
    }
    function _setVenueRate(uint256 rate) internal override {
        MockBalancerVault(vault).setRate(rate);
    }
    function _expectedOut(uint256 amountIn) internal view override returns (uint256) {
        return (amountIn * MockBalancerVault(vault).rate()) / 1e18;
    }
    function _setVenueLiar() internal override {
        MockBalancerVault(vault).setHonourLimit(false);
        MockBalancerVault(vault).setRate(MockBalancerVault(vault).rate() / 2);
    }

    // ── UUPS behaviour hooks ──────────────────────────────────────────
    function _uupsProxyTarget() internal view override returns (address) {
        return balancerSwapperProxy;
    }
    function _uupsNonOwner() internal view override returns (address) {
        return alice;
    }
    function _uupsCallInitialize(address target) internal override {
        BalancerSwapper_v1(target).initialize(address(1), address(2));
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

    /// @dev Non-unity fixture rate with a DECIMALS GAP baked in: the Vault mints out-units
    ///      per in-unit ×1e18, and the fixture pair is 6-decimals → 18-decimals (a
    ///      USDC→WETH-like direction, the opposite gap to the UniV3 fixture). 1e6 in-units ≈
    ///      0.000447e18 out-wei, so the rate is 0.000447e18 × 1e12 = 0.000447e30.
    uint256 constant BALANCER_RATE = 0.000447e30;

    /// @dev 1000 whole units of the 6-decimals fromToken.
    uint256 constant AMOUNT_IN = 1_000e6;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fromToken = address(new MockERC20("From Token", "FROM", 6));
        toToken = address(new MockERC20("To Token", "TO", 18));

        vault = address(new MockBalancerVault());
        MockBalancerVault(vault).setRate(BALANCER_RATE);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
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

    /// @notice Configured pool ID: Vault.swap is invoked; the rate-scaled toToken output
    ///         arrives at the caller.
    function test_swap_happyPath() public {
        _configureRoute();
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);

        uint256 amountOut = ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);

        assertEq(amountOut, _expectedOut(amountIn), "vault-rate-scaled output");
        assertEq(IERC20(toToken).balanceOf(address(this)), amountOut);
        assertEq(IERC20(fromToken).balanceOf(address(this)), 0);
    }

    /// @notice VAULT immutable matches the deploy-wired address.
    function test_vault_immutable_isSet() public view {
        assertEq(BalancerSwapper_v1(balancerSwapperProxy).VAULT(), vault);
    }

    /// @notice No configured route -> NoRouteConfigured.
    function test_swap_noRoute_reverts() public {
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(BalancerSwapper_v1.NoRouteConfigured.selector, fromToken, toToken));
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice The Vault's own limit enforcement reverts when minAmountOut exceeds the
    ///         Vault's output (typed call, so the Vault error bubbles unwrapped — the real
    ///         Vault reverts Errors.SWAP_LIMIT as "BAL#507").
    function test_swap_slippage_reverts() public {
        _configureRoute();
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);
        // Hoisted: an argument sub-expression making an external call would steal the
        // expectRevert binding.
        uint256 minTooHigh = _expectedOut(amountIn) + 1;

        vm.expectRevert(bytes("BAL#507"));
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, minTooHigh);
    }

    /// @notice A forced Vault revert bubbles unwrapped (typed call — no wrapper error).
    function test_swap_vaultRevert_surfacesError() public {
        _configureRoute();
        MockBalancerVault(vault).setShouldRevert(true);
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);

        vm.expectRevert(bytes("MockBalancerVault: forced revert"));
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice Vault allowance is cleared to zero after every swap.
    function test_swap_approvalsCleared() public {
        _configureRoute();
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn);
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        assertEq(IERC20(fromToken).allowance(balancerSwapperProxy, vault), 0);
    }

    /// @notice fromToken pulled from msg.sender; toToken delivered to msg.sender.
    function test_swap_tokensTransferred() public {
        _configureRoute();
        uint256 amountIn = 3 * AMOUNT_IN;
        MockERC20(fromToken).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fromToken).approve(balancerSwapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
        vm.stopPrank();

        assertEq(IERC20(fromToken).balanceOf(alice), 0);
        assertEq(IERC20(toToken).balanceOf(alice), amountOut);
    }

    /// @notice Re-entrant call from the Vault is blocked by nonReentrant; the mock bubbles
    ///         the guard's error unchanged and the typed call re-bubbles it.
    function test_swap_reentrancyGuard() public {
        _configureRoute();
        uint256 amountIn = AMOUNT_IN;
        _mintAndApprove(fromToken, balancerSwapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fromToken, toToken, amountIn, 0));
        MockBalancerVault(vault).setReentrantCall(balancerSwapperProxy, reentrantCall);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ISwapExecutor(balancerSwapperProxy).swap(fromToken, toToken, amountIn, 0);
    }

    /// @notice A fee-on-transfer fromToken delivers less than amountIn to the executor and is
    ///         rejected up front with UnexpectedAmountIn (exact expected/received amounts).
    function test_swap_feeOnTransferFromToken_reverts() public {
        uint256 feeBps = 100; // 1%
        address fot = address(new MockFeeOnTransferERC20("Fee Token", "FEE", feeBps));
        uint256 amountIn = 1 ether;
        MockFeeOnTransferERC20(fot).mint(address(this), amountIn);
        IERC20(fot).approve(balancerSwapperProxy, amountIn);
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fot, toToken, POOL_ID);

        uint256 received = amountIn - (amountIn * feeBps) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(SwapExecutorBase.UnexpectedAmountIn.selector, amountIn, received));
        ISwapExecutor(balancerSwapperProxy).swap(fot, toToken, amountIn, 0);
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
        vm.startPrank(alice);
        vm.expectRevert(IOwnable.Unauthorized.selector);
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken, toToken, POOL_ID);
        vm.stopPrank();
    }

    /// @notice Address granted ROUTE_SETTER_ROLE can call setRoute without owning.
    function test_setRoute_calledByRouteSetter_succeeds() public {
        BalancerSwapper_v1(balancerSwapperProxy).grantRoles(
            routeSetter,
            BalancerSwapper_v1(balancerSwapperProxy).ROUTE_SETTER_ROLE()
        );

        vm.startPrank(routeSetter);
        BalancerSwapper_v1(balancerSwapperProxy).setRoute(fromToken, toToken, POOL_ID);
        vm.stopPrank();

        assertEq(BalancerSwapper_v1(balancerSwapperProxy).poolIds(fromToken, toToken), POOL_ID);
    }
}
