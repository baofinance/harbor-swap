// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests FxSaveWstEthSwapper_v1: bidirectional fxSAVE ↔ wstETH composite routes (Curve pools,
// scrvUSD vault, UniV3 ETH stack hop), slippage on final output, unsupported pair revert,
// approval reset, token transfer, pool/vault failure paths, and reentrancy guard.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockERC4626Vault} from "@harbor-swap-test-mocks/MockERC4626Vault.sol";
import {MockCurveStableSwapPool} from "@harbor-swap-test-mocks/MockCurveStableSwapPool.sol";
import {MockFxSaveScrvUsdPool} from "@harbor-swap-test-mocks/MockFxSaveScrvUsdPool.sol";
import {MockUniV3Router} from "@harbor-swap-test-mocks/MockUniV3Router.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Token} from "@bao/Token.sol";
import {FxSaveWstEthSwapper_v1} from "@harbor-swap/executors/FxSaveWstEthSwapper_v1.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {UUPSOwnableTestBase} from "@bao-test/helpers/UUPSOwnableTestBase.t.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract FxSaveWstEthSwapperHarness is FxSaveWstEthSwapper_v1 {
    struct RouteCfg {
        address fxSave;
        address wstEth;
        address usdc;
        address crvUsd;
        address scrvUsdVault;
        address poolFxSaveScrvUsd;
        address poolCrvUsdUsdc;
        int128 pool2IFxSave;
        int128 pool2JScrvUsd;
        int128 poolUsdIUsdc;
        int128 poolUsdJCrvUsd;
    }

    address private immutable _fxSaveToken;
    address private immutable _wstEthToken;
    address private immutable _usdcToken;
    address private immutable _crvUsdToken;
    address private immutable _scrvUsdVaultToken;
    address private immutable _poolFxSaveScrvUsdAddr;
    address private immutable _poolCrvUsdUsdcAddr;
    int128 private immutable _pool2IFxSaveIdx;
    int128 private immutable _pool2JScrvUsdIdx;
    int128 private immutable _poolUsdIUsdcIdx;
    int128 private immutable _poolUsdJCrvUsdIdx;

    constructor(address uniV3Router_, RouteCfg memory cfg_) FxSaveWstEthSwapper_v1(uniV3Router_) {
        _fxSaveToken = cfg_.fxSave;
        _wstEthToken = cfg_.wstEth;
        _usdcToken = cfg_.usdc;
        _crvUsdToken = cfg_.crvUsd;
        _scrvUsdVaultToken = cfg_.scrvUsdVault;
        _poolFxSaveScrvUsdAddr = cfg_.poolFxSaveScrvUsd;
        _poolCrvUsdUsdcAddr = cfg_.poolCrvUsdUsdc;
        _pool2IFxSaveIdx = cfg_.pool2IFxSave;
        _pool2JScrvUsdIdx = cfg_.pool2JScrvUsd;
        _poolUsdIUsdcIdx = cfg_.poolUsdIUsdc;
        _poolUsdJCrvUsdIdx = cfg_.poolUsdJCrvUsd;
    }

    function _fxSave() internal view override returns (address) {
        return _fxSaveToken;
    }

    function _wstEth() internal view override returns (address) {
        return _wstEthToken;
    }

    function _usdc() internal view override returns (address) {
        return _usdcToken;
    }

    function _crvUsd() internal view override returns (address) {
        return _crvUsdToken;
    }

    function _scrvUsdVault() internal view override returns (address) {
        return _scrvUsdVaultToken;
    }

    function _poolFxSaveScrvUsd() internal view override returns (address) {
        return _poolFxSaveScrvUsdAddr;
    }

    function _poolCrvUsdUsdc() internal view override returns (address) {
        return _poolCrvUsdUsdcAddr;
    }

    function _pool2IFxSave() internal view override returns (int128) {
        return _pool2IFxSaveIdx;
    }

    function _pool2JScrvUsd() internal view override returns (int128) {
        return _pool2JScrvUsdIdx;
    }

    function _poolUsdIUsdc() internal view override returns (int128) {
        return _poolUsdIUsdcIdx;
    }

    function _poolUsdJCrvUsd() internal view override returns (int128) {
        return _poolUsdJCrvUsdIdx;
    }

    // Rebuild path from immutables — UUPS proxy storage would not see constructor-written bytes.
    function _uniPathUsdcToWstEth() internal view override returns (bytes memory) {
        return abi.encodePacked(_usdcToken, uint24(500), address(uint160(1)), uint24(100), _wstEthToken);
    }

    function _uniPathWstEthToUsdc() internal view override returns (bytes memory) {
        return abi.encodePacked(_wstEthToken, uint24(100), address(uint160(1)), uint24(500), _usdcToken);
    }
}

contract FxSaveWstEthSwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, UUPSOwnableTestBase, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal view override returns (address) {
        return uniRouter;
    }

    function _tokenHolderTarget() internal view override returns (address) {
        return swapperProxy;
    }

    function _tokenHolderSweepToken() internal view override returns (address) {
        return crvUSD;
    }

    function _tokenHolderNonOwner() internal view override returns (address) {
        return alice;
    }

    function _swapExecutorTarget() internal view override returns (address) {
        return swapperProxy;
    }

    function _swapFromToken() internal view override returns (address) {
        return fxSAVE;
    }

    function _swapToToken() internal view override returns (address) {
        return wstETH;
    }

    function _swapCall(
        address fromToken_,
        address toToken_,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal override returns (uint256) {
        return ISwapExecutor(swapperProxy).swap(fromToken_, toToken_, amountIn, minAmountOut);
    }

    /// @dev The forward route's output leg is the Uni mock (USDC -> wstETH).
    function _setVenueRate(uint256 rate) internal override {
        MockUniV3Router(uniRouter).setRate(rate);
    }

    function _expectedOut(uint256 amountIn) internal view override returns (uint256) {
        (, uint256 wstEthOut) = _forwardQuote(amountIn);
        return wstEthOut;
    }

    function _setVenueLiar() internal override {
        MockUniV3Router(uniRouter).setHonourMin(false);
        MockUniV3Router(uniRouter).setRate(MockUniV3Router(uniRouter).rate() / 2);
    }

    function _uupsProxyTarget() internal view override returns (address) {
        return swapperProxy;
    }

    function _uupsNonOwner() internal view override returns (address) {
        return alice;
    }

    function _uupsCallInitialize(address target) internal override {
        FxSaveWstEthSwapper_v1(target).initialize(address(1), address(2));
    }

    // Fixture tokens are 18 decimals BY CONSTRUCTION (production USDC is 6; the mocks keep
    // a single scale so quote composition stays exact without decimals plumbing).
    address fxSAVE;
    address wstETH;
    address usdc;
    address crvUSD;
    address scrvUsdVault;
    address poolFxSaveScrvUsd;
    address poolCrvUsdUsdc;
    address uniRouter;
    address swapperProxy;
    address alice = makeAddr("alice");

    string constant SALT_PREFIX = "test_fxsave_wsteth_swapper";

    int128 constant POOL2_I = 0;
    int128 constant POOL2_J = 1;
    int128 constant POOL_USD_I = 0;
    int128 constant POOL_USD_J = 1;

    uint256 constant FXSAVE_POOL_RATE = 1.0013e18;
    uint256 constant CRVUSD_USDC_RATE = 1e18;
    uint256 constant UNI_RATE = 0.000447e18;
    uint256 constant VAULT_SEED_ASSETS = 1000 ether;
    uint256 constant VAULT_SEED_YIELD = 104.6 ether;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fxSAVE = address(new MockERC20("fxSAVE", "fxSAVE", 18));
        wstETH = address(new MockERC20("wstETH", "wstETH", 18));
        usdc = address(new MockERC20("USDC", "USDC", 18));
        crvUSD = address(new MockERC20("crvUSD", "crvUSD", 18));

        scrvUsdVault = address(new MockERC4626Vault(IERC20(crvUSD), "scrvUSD", "scrvUSD"));
        MockERC20(crvUSD).mint(address(this), VAULT_SEED_ASSETS);
        IERC20(crvUSD).approve(scrvUsdVault, VAULT_SEED_ASSETS);
        IERC4626(scrvUsdVault).deposit(VAULT_SEED_ASSETS, address(this));
        MockERC4626Vault(scrvUsdVault).addYield(VAULT_SEED_YIELD);

        poolFxSaveScrvUsd = address(new MockFxSaveScrvUsdPool(fxSAVE, IERC4626(scrvUsdVault)));
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setRate(FXSAVE_POOL_RATE);

        poolCrvUsdUsdc = address(new MockCurveStableSwapPool());
        MockCurveStableSwapPool(poolCrvUsdUsdc).setCoin(POOL_USD_I, usdc);
        MockCurveStableSwapPool(poolCrvUsdUsdc).setCoin(POOL_USD_J, crvUSD);
        MockCurveStableSwapPool(poolCrvUsdUsdc).setRate(CRVUSD_USDC_RATE);

        uniRouter = address(new MockUniV3Router());
        MockUniV3Router(uniRouter).setRate(UNI_RATE);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployFxSaveWstEthSwapper(state);
        swapperProxy = _predictAddress("fxSaveWstEthSwapper");
    }

    function _forwardQuote(uint256 amountIn) internal view returns (uint256 crvUsdOut, uint256 wstEthOut) {
        uint256 crvUsdMinted = (amountIn * MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).rate()) / 1e18;
        uint256 shares = IERC4626(scrvUsdVault).previewDeposit(crvUsdMinted);
        crvUsdOut = Math.mulDiv(
            shares,
            IERC4626(scrvUsdVault).totalAssets() + crvUsdMinted + 1,
            IERC20(scrvUsdVault).totalSupply() + shares + 1
        );
        uint256 usdcOut = (crvUsdOut * MockCurveStableSwapPool(poolCrvUsdUsdc).rate()) / 1e18;
        wstEthOut = (usdcOut * MockUniV3Router(uniRouter).rate()) / 1e18;
    }

    function _reverseQuote(uint256 amountIn) internal view returns (uint256 crvUsdIntermediate, uint256 fxSaveOut) {
        uint256 usdcOut = (amountIn * MockUniV3Router(uniRouter).rate()) / 1e18;
        crvUsdIntermediate = (usdcOut * MockCurveStableSwapPool(poolCrvUsdUsdc).rate()) / 1e18;
        uint256 shares = IERC4626(scrvUsdVault).previewDeposit(crvUsdIntermediate);
        fxSaveOut = (shares * MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).rate()) / 1e18;
    }

    function deployFxSaveWstEthSwapperImplementation(address uniV3Router_) internal override returns (address) {
        return
            address(
                new FxSaveWstEthSwapperHarness(
                    uniV3Router_,
                    FxSaveWstEthSwapperHarness.RouteCfg({
                        fxSave: fxSAVE,
                        wstEth: wstETH,
                        usdc: usdc,
                        crvUsd: crvUSD,
                        scrvUsdVault: scrvUsdVault,
                        poolFxSaveScrvUsd: poolFxSaveScrvUsd,
                        poolCrvUsdUsdc: poolCrvUsdUsdc,
                        pool2IFxSave: POOL2_I,
                        pool2JScrvUsd: POOL2_J,
                        poolUsdIUsdc: POOL_USD_I,
                        poolUsdJCrvUsd: POOL_USD_J
                    })
                )
            );
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    function test_swap_fxSaveToWstEth_happyPath() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);
        (uint256 crvUsdOut, uint256 wstEthOut) = _forwardQuote(amountIn);

        vm.expectEmit(true, true, true, true);
        emit FxSaveWstEthSwapper_v1.FxSaveWstEthSwap(address(this), fxSAVE, wstETH, amountIn, crvUsdOut);

        uint256 amountOut = ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);

        assertEq(amountOut, wstEthOut, "quote-composed wstETH out");
        assertEq(IERC20(wstETH).balanceOf(address(this)), amountOut);
    }

    function test_swap_fxSaveToWstEth_revertsOnSlippage() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(bytes("Too little received"));
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, amountIn + 1);
    }

    function test_swap_wstEthToFxSave_happyPath() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);
        (uint256 crvUsdIntermediate, uint256 fxSaveOut) = _reverseQuote(amountIn);

        vm.expectEmit(true, true, true, true);
        emit FxSaveWstEthSwapper_v1.FxSaveWstEthSwap(address(this), wstETH, fxSAVE, amountIn, crvUsdIntermediate);

        uint256 amountOut = ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);

        assertEq(amountOut, fxSaveOut, "quote-composed fxSAVE out");
        assertEq(IERC20(fxSAVE).balanceOf(address(this)), amountOut);
    }

    function test_swap_wstEthToFxSave_revertsOnSlippage() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "MockFxSaveScrvUsdPool: slippage")
            )
        );
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, amountIn + 1);
    }

    function test_swap_unsupportedPair_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(FxSaveWstEthSwapper_v1.UnsupportedPair.selector, fxSAVE, crvUSD));
        ISwapExecutor(swapperProxy).swap(fxSAVE, crvUSD, amountIn, 0);
    }

    function test_swap_fxSaveToWstEth_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);

        assertEq(IERC20(fxSAVE).allowance(swapperProxy, poolFxSaveScrvUsd), 0);
        assertEq(IERC20(scrvUsdVault).allowance(swapperProxy, scrvUsdVault), 0);
        assertEq(IERC20(crvUSD).allowance(swapperProxy, poolCrvUsdUsdc), 0);
        assertEq(IERC20(usdc).allowance(swapperProxy, uniRouter), 0);
    }

    function test_swap_wstEthToFxSave_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);

        assertEq(IERC20(wstETH).allowance(swapperProxy, uniRouter), 0);
        assertEq(IERC20(usdc).allowance(swapperProxy, poolCrvUsdUsdc), 0);
        assertEq(IERC20(crvUSD).allowance(swapperProxy, scrvUsdVault), 0);
        assertEq(IERC20(scrvUsdVault).allowance(swapperProxy, poolFxSaveScrvUsd), 0);
    }

    function test_swap_fxSaveToWstEth_tokensTransferred() public {
        uint256 amountIn = 3 ether;
        MockERC20(fxSAVE).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(fxSAVE).approve(swapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
        vm.stopPrank();

        assertEq(IERC20(fxSAVE).balanceOf(alice), 0);
        assertEq(IERC20(wstETH).balanceOf(alice), amountOut);
    }

    function test_swap_wstEthToFxSave_tokensTransferred() public {
        uint256 amountIn = 3 ether;
        MockERC20(wstETH).mint(alice, amountIn);

        vm.startPrank(alice);
        IERC20(wstETH).approve(swapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);
        vm.stopPrank();

        assertEq(IERC20(wstETH).balanceOf(alice), 0);
        assertEq(IERC20(fxSAVE).balanceOf(alice), amountOut);
    }

    function test_swap_fxSaveToWstEth_ignoresDonatedIntermediate() public {
        uint256 amountIn = 1 ether;
        uint256 donation = 0.5 ether;

        MockERC20(crvUSD).mint(address(this), donation);
        IERC20(crvUSD).approve(scrvUsdVault, donation);
        IERC4626(scrvUsdVault).deposit(donation, swapperProxy);
        uint256 donationShares = IERC20(scrvUsdVault).balanceOf(swapperProxy);
        assertGt(donationShares, 0, "donation seeded");

        _mintAndApprove(fxSAVE, swapperProxy, amountIn);
        (, uint256 wstEthOut) = _forwardQuote(amountIn);
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);

        assertEq(amountOut, wstEthOut, "donation not swept into output");
        assertEq(IERC20(scrvUsdVault).balanceOf(swapperProxy), donationShares, "donation untouched");
    }

    function test_swap_wstEthToFxSave_ignoresDonatedIntermediate() public {
        uint256 amountIn = 1 ether;
        uint256 donation = 0.5 ether;

        MockERC20(crvUSD).mint(swapperProxy, donation);
        assertEq(IERC20(crvUSD).balanceOf(swapperProxy), donation, "donation seeded");

        _mintAndApprove(wstETH, swapperProxy, amountIn);
        (, uint256 fxSaveOut) = _reverseQuote(amountIn);
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);

        assertEq(amountOut, fxSaveOut, "donation not swept into output");
        assertEq(IERC20(crvUSD).balanceOf(swapperProxy), donation, "donation untouched");
    }

    function test_swap_fxSaveToWstEth_poolRevert_surfacesError() public {
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "MockFxSaveScrvUsdPool: forced revert")
            )
        );
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
    }

    function test_swap_fxSaveToWstEth_zeroLegOneOutput_reverts() public {
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setRate(0);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, scrvUsdVault));
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
    }

    function test_swap_wstEthToFxSave_zeroLegOneOutput_reverts() public {
        MockUniV3Router(uniRouter).setRate(0);
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, usdc));
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);
    }

    function test_swap_fxSaveToWstEth_vaultReturnsZeroAssets_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.mockCall(scrvUsdVault, abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode(uint256(0)));
        vm.expectRevert(FxSaveWstEthSwapper_v1.VaultRedeemFailed.selector);
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
        vm.clearMockedCalls();
    }

    function test_swap_wstEthToFxSave_vaultReturnsZeroShares_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.mockCall(scrvUsdVault, abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode(uint256(0)));
        vm.expectRevert(FxSaveWstEthSwapper_v1.VaultDepositFailed.selector);
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);
        vm.clearMockedCalls();
    }

    function test_swap_fxSaveToWstEth_reentrancyGuard() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fxSAVE, wstETH, amountIn, 0));
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setReentrantCall(swapperProxy, reentrantCall);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveExchangeLib.PoolCallFailed.selector,
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            )
        );
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
    }

    function test_swap_wstEthToFxSave_reentrancyGuard() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (wstETH, fxSAVE, amountIn, 0));
        MockUniV3Router(uniRouter).setReentrantCall(swapperProxy, reentrantCall);

        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);
    }
}
