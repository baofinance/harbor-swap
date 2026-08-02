// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for BalancerSwapper_v1 against the real mainnet Balancer V2 Vault and the
// wstETH/WETH MetaStable pool: end-to-end execution quoted via the Vault's own
// queryBatchSwap, and the Vault's limit enforcement (whose real "BAL#507" revert string the
// unit mock mirrors). The pool holds little liquidity in the V2 sunset era, so the amount is
// deliberately small — the test validates the executor's mechanics against the real Vault
// ABI, not pool depth.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {BalancerSwapper_v1, IBalancerV2Vault} from "@harbor-swap/executors/BalancerSwapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface IBalancerVaultQuery {
    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    function queryBatchSwap(
        IBalancerV2Vault.SwapKind kind,
        BatchSwapStep[] calldata swaps,
        address[] calldata assets,
        IBalancerV2Vault.FundManagement calldata funds
    ) external returns (int256[] memory assetDeltas);
}

contract BalancerSwapperForkTest is ForkTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return address(0);
    }

    address constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 constant POOL_ID = 0x32296969ef14eb0c6d29669c550d4a0449130230000200000000000000000080;

    address balancerSwapperProxy;
    string constant SALT_PREFIX = "fork_balancerswapper";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        deployBalancerSwapper(state, VAULT);
        balancerSwapperProxy = _predictAddress("balancerSwapper");

        BalancerSwapper_v1(balancerSwapperProxy).setRoute(WSTETH, WETH, POOL_ID);
    }

    /// @dev The Vault's own simulation of the single swap — the canonical Balancer quote.
    function _queryExpected(uint256 amountIn) internal returns (uint256 expected) {
        IBalancerVaultQuery.BatchSwapStep[] memory steps = new IBalancerVaultQuery.BatchSwapStep[](1);
        steps[0] = IBalancerVaultQuery.BatchSwapStep({
            poolId: POOL_ID,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: amountIn,
            userData: ""
        });
        address[] memory assets = new address[](2);
        assets[0] = WSTETH;
        assets[1] = WETH;
        int256[] memory deltas = IBalancerVaultQuery(VAULT).queryBatchSwap(
            IBalancerV2Vault.SwapKind.GIVEN_IN,
            steps,
            assets,
            IBalancerV2Vault.FundManagement({
                sender: balancerSwapperProxy,
                fromInternalBalance: false,
                recipient: payable(balancerSwapperProxy),
                toInternalBalance: false
            })
        );
        expected = uint256(-deltas[1]);
    }

    /// @notice A real wstETH -> WETH swap through the Vault delivers the queryBatchSwap-quoted
    ///         amount to the caller with nothing left in the executor.
    function test_fork_swap_wstEthToWeth_executes() public {
        uint256 amountIn = 0.001 ether; // small: the V2 pool holds little in the sunset era
        deal(WSTETH, address(this), amountIn);

        uint256 expected = _queryExpected(amountIn);
        assertGt(expected, 0, "sanity: vault quotes a non-zero WETH amount");

        IERC20(WSTETH).approve(balancerSwapperProxy, amountIn);
        // Delta, not absolute: on a mainnet fork the test contract's deterministic address
        // can already hold real WETH.
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        // The floor is a RATE — output per 1e18 of input — so the quote is converted before the
        // 1% tolerance is applied to it.
        uint256 minRate = (((expected * 1 ether) / amountIn) * 99) / 100;
        uint256 amountOut = ISwapExecutor(balancerSwapperProxy).swap(WSTETH, WETH, amountIn, minRate);

        assertApproxEqRel(amountOut, expected, 0.001e18, "WETH out must match the Vault's own quote");
        assertEq(IERC20(WETH).balanceOf(address(this)) - wethBefore, amountOut, "WETH delivered to caller");
        assertEq(IERC20(WSTETH).balanceOf(balancerSwapperProxy), 0, "no wstETH residue");
        assertEq(IERC20(WETH).balanceOf(balancerSwapperProxy), 0, "no WETH residue");
        assertEq(IERC20(WSTETH).allowance(balancerSwapperProxy, VAULT), 0, "approval cleared");
    }

    /// @notice A minAmountOut above the quote reverts inside the real Vault with its
    ///         "BAL#507" (SWAP_LIMIT) string — the exact string the unit mock mirrors.
    function test_fork_swap_aboveQuoteMinAmountOut_reverts() public {
        uint256 amountIn = 0.001 ether;
        deal(WSTETH, address(this), amountIn);
        uint256 expected = _queryExpected(amountIn);

        IERC20(WSTETH).approve(balancerSwapperProxy, amountIn);
        // The floor is a RATE — output per 1e18 of input — so the quote is converted before being
        // pushed 1% above what the pool will actually pay.
        uint256 rateTooHigh = (((expected * 1 ether) / amountIn) * 101) / 100;

        vm.expectRevert(bytes("BAL#507"));
        ISwapExecutor(balancerSwapperProxy).swap(WSTETH, WETH, amountIn, rateTooHigh);
    }
}
