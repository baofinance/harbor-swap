// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fork tests for UniV3Swapper_v1 against the real mainnet SwapRouter and the USDC/WETH 0.05%
// pool: end-to-end execution quoted via the canonical Quoter, and the router's own
// amountOutMinimum enforcement (whose real revert string the unit mock mirrors).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {ForkTestBase} from "@harbor-swap-test/fork/ForkTestBase.sol";
import {UniV3Swapper_v1} from "@harbor-swap/executors/UniV3Swapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

interface IUniV3Quoter {
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);
}

contract UniV3SwapperForkTest is ForkTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal pure override returns (address) {
        return SWAP_ROUTER;
    }

    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint24 constant FEE = 500; // USDC/WETH 0.05%

    address uniV3SwapperProxy;
    string constant SALT_PREFIX = "fork_univ3swapper";

    function setUp() public {
        _forkMainnet();
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "fork");
        state.baoFactory = baoFactory();
        deployUniV3Swapper(state, SWAP_ROUTER);
        uniV3SwapperProxy = _predictAddress("uniV3Swapper");

        UniV3Swapper_v1(uniV3SwapperProxy).setPath(USDC, WETH, abi.encodePacked(USDC, FEE, WETH));
    }

    /// @notice A real USDC -> WETH swap through the SwapRouter delivers the Quoter's quoted
    ///         amount to the caller with nothing left in the executor.
    function test_fork_swap_usdcToWeth_executes() public {
        uint256 amountIn = 1_000e6; // 1000 USDC
        deal(USDC, address(this), amountIn);

        uint256 expected = IUniV3Quoter(QUOTER).quoteExactInput(abi.encodePacked(USDC, FEE, WETH), amountIn);
        assertGt(expected, 0, "sanity: quoter returns a non-zero WETH amount");

        IERC20(USDC).approve(uniV3SwapperProxy, amountIn);
        // Delta, not absolute: on a mainnet fork the test contract's deterministic address
        // can already hold real WETH.
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        // The floor is a RATE — output per 1e18 of input — so the quote is converted before the
        // 1% tolerance is applied to it.
        uint256 minRate = (((expected * 1 ether) / amountIn) * 99) / 100;
        uint256 amountOut = ISwapExecutor(uniV3SwapperProxy).swap(USDC, WETH, amountIn, minRate);

        assertApproxEqRel(amountOut, expected, 0.001e18, "WETH out must match the Quoter quote");
        assertEq(IERC20(WETH).balanceOf(address(this)) - wethBefore, amountOut, "WETH delivered to caller");
        assertEq(IERC20(USDC).balanceOf(uniV3SwapperProxy), 0, "no USDC residue");
        assertEq(IERC20(WETH).balanceOf(uniV3SwapperProxy), 0, "no WETH residue");
        assertEq(IERC20(USDC).allowance(uniV3SwapperProxy, SWAP_ROUTER), 0, "approval cleared");
    }

    /// @notice A minAmountOut above the quote reverts inside the real router with its
    ///         "Too little received" string — the exact string the unit mock mirrors.
    function test_fork_swap_aboveQuoteMinAmountOut_reverts() public {
        uint256 amountIn = 1_000e6;
        deal(USDC, address(this), amountIn);
        uint256 expected = IUniV3Quoter(QUOTER).quoteExactInput(abi.encodePacked(USDC, FEE, WETH), amountIn);

        IERC20(USDC).approve(uniV3SwapperProxy, amountIn);
        // The floor is a RATE — output per 1e18 of input — so the quote is converted before being
        // pushed 1% above what the pool will actually pay.
        uint256 rateTooHigh = (((expected * 1 ether) / amountIn) * 101) / 100;

        vm.expectRevert(bytes("Too little received"));
        ISwapExecutor(uniV3SwapperProxy).swap(USDC, WETH, amountIn, rateTooHigh);
    }
}
