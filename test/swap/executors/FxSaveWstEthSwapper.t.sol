// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Tests FxSaveWstEthSwapper_v1: bidirectional fxSAVE ↔ wstETH composite routes (Curve pools,
// scrvUSD vault deposit/redeem), slippage on final output, unsupported pair revert, approval
// reset, token transfer, pool/vault failure paths, and reentrancy guard.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockERC4626Vault} from "@harbor-swap-test-mocks/MockERC4626Vault.sol";
import {MockCurvePool} from "@harbor-swap-test-mocks/MockCurvePool.sol";
import {MockFxSaveScrvUsdPool} from "@harbor-swap-test-mocks/MockFxSaveScrvUsdPool.sol";

import {Token} from "@bao/Token.sol";
import {FxSaveWstEthSwapper_v1} from "@harbor-swap/executors/FxSaveWstEthSwapper_v1.sol";
import {CurveExchangeLib} from "@harbor-swap/executors/CurveExchangeLib.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {SwapExecutorTestBase} from "@harbor-swap-test/SwapExecutorTestBase.sol";
import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

contract FxSaveWstEthSwapperHarness is FxSaveWstEthSwapper_v1 {
    struct RouteCfg {
        address fxSave;
        address wstEth;
        address crvUsd;
        address scrvUsdVault;
        address poolFxSaveScrvUsd;
        address poolTricryptoLlama;
        int128 pool2IFxSave;
        int128 pool2JScrvUsd;
        int128 pool1ICrvUsd;
        int128 pool1JWstEth;
    }

    address private immutable _fxSaveToken;
    address private immutable _wstEthToken;
    address private immutable _crvUsdToken;
    address private immutable _scrvUsdVaultToken;
    address private immutable _poolFxSaveScrvUsdAddr;
    address private immutable _poolTricryptoLlamaAddr;
    int128 private immutable _pool2IFxSaveIdx;
    int128 private immutable _pool2JScrvUsdIdx;
    int128 private immutable _pool1ICrvUsdIdx;
    int128 private immutable _pool1JWstEthIdx;

    constructor(RouteCfg memory cfg_) {
        _fxSaveToken = cfg_.fxSave;
        _wstEthToken = cfg_.wstEth;
        _crvUsdToken = cfg_.crvUsd;
        _scrvUsdVaultToken = cfg_.scrvUsdVault;
        _poolFxSaveScrvUsdAddr = cfg_.poolFxSaveScrvUsd;
        _poolTricryptoLlamaAddr = cfg_.poolTricryptoLlama;
        _pool2IFxSaveIdx = cfg_.pool2IFxSave;
        _pool2JScrvUsdIdx = cfg_.pool2JScrvUsd;
        _pool1ICrvUsdIdx = cfg_.pool1ICrvUsd;
        _pool1JWstEthIdx = cfg_.pool1JWstEth;
    }

    function _fxSave() internal view override returns (address) {
        return _fxSaveToken;
    }

    function _wstEth() internal view override returns (address) {
        return _wstEthToken;
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

    function _poolTricryptoLlama() internal view override returns (address) {
        return _poolTricryptoLlamaAddr;
    }

    // Both mock pools implement the StableSwap (int128) `exchange` ABI, so both legs are
    // declared StableSwap here; the production Tricrypto leg is Crypto (uint256) and is
    // exercised by the fork tests against the real pool.
    function _poolFxSaveScrvUsdKind() internal pure override returns (CurveExchangeLib.CurvePoolKind) {
        return CurveExchangeLib.CurvePoolKind.StableSwap;
    }

    function _poolTricryptoLlamaKind() internal pure override returns (CurveExchangeLib.CurvePoolKind) {
        return CurveExchangeLib.CurvePoolKind.StableSwap;
    }

    function _pool2IFxSave() internal view override returns (int128) {
        return _pool2IFxSaveIdx;
    }

    function _pool2JScrvUsd() internal view override returns (int128) {
        return _pool2JScrvUsdIdx;
    }

    function _pool1ICrvUsd() internal view override returns (int128) {
        return _pool1ICrvUsdIdx;
    }

    function _pool1JWstEth() internal view override returns (int128) {
        return _pool1JWstEthIdx;
    }
}

contract FxSaveWstEthSwapperTest is BaoTest, TokenHolderTestBase, SwapExecutorTestBase, Swapper {
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

    /// @dev The forward route's output leg is the Tricrypto mock (crvUSD -> wstETH).
    function _setVenueRate(uint256 rate) internal override {
        MockCurvePool(poolTricryptoLlama).setRate(rate);
    }

    address fxSAVE;
    address wstETH;
    address crvUSD;
    address scrvUsdVault;
    address poolFxSaveScrvUsd;
    address poolTricryptoLlama;
    address swapperProxy;
    address alice = makeAddr("alice");

    string constant SALT_PREFIX = "test_fxsave_wsteth_swapper";

    int128 constant POOL2_I = 0;
    int128 constant POOL2_J = 1;
    int128 constant POOL1_I = 0;
    int128 constant POOL1_J = 2;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT_PREFIX);

        fxSAVE = address(new MockERC20("fxSAVE", "fxSAVE", 18));
        wstETH = address(new MockERC20("wstETH", "wstETH", 18));
        crvUSD = address(new MockERC20("crvUSD", "crvUSD", 18));

        scrvUsdVault = address(new MockERC4626Vault(IERC20(crvUSD), "scrvUSD", "scrvUSD"));
        poolFxSaveScrvUsd = address(new MockFxSaveScrvUsdPool(fxSAVE, IERC4626(scrvUsdVault)));

        poolTricryptoLlama = address(new MockCurvePool());
        MockCurvePool(poolTricryptoLlama).setCoin(POOL1_I, crvUSD);
        MockCurvePool(poolTricryptoLlama).setCoin(POOL1_J, wstETH);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT_PREFIX, "test");
        state.baoFactory = baoFactory();
        deployFxSaveWstEthSwapper(state);
        swapperProxy = _predictAddress("fxSaveWstEthSwapper");
    }

    function deployFxSaveWstEthSwapperImplementation() internal override returns (address) {
        return
            address(
                new FxSaveWstEthSwapperHarness(
                    FxSaveWstEthSwapperHarness.RouteCfg({
                        fxSave: fxSAVE,
                        wstEth: wstETH,
                        crvUsd: crvUSD,
                        scrvUsdVault: scrvUsdVault,
                        poolFxSaveScrvUsd: poolFxSaveScrvUsd,
                        poolTricryptoLlama: poolTricryptoLlama,
                        pool2IFxSave: POOL2_I,
                        pool2JScrvUsd: POOL2_J,
                        pool1ICrvUsd: POOL1_I,
                        pool1JWstEth: POOL1_J
                    })
                )
            );
    }

    function _mintAndApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    /// @notice Full composite route delivers wstETH to the caller at 1:1 mock rates.
    function test_swap_fxSaveToWstEth_happyPath() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectEmit(true, true, true, true);
        emit FxSaveWstEthSwapper_v1.FxSaveWstEthSwap(address(this), fxSAVE, wstETH, amountIn, amountIn);

        uint256 amountOut = ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);

        assertEq(amountOut, amountIn, "mock 1:1 wstETH out");
        assertEq(IERC20(wstETH).balanceOf(address(this)), amountIn);
    }

    /// @notice Final-leg Curve min_dy reverts when minAmountOut exceeds mock output (forward).
    function test_swap_fxSaveToWstEth_revertsOnSlippage() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert();
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, amountIn + 1);
    }

    /// @notice Full composite route delivers fxSAVE to the caller at 1:1 mock rates (reverse).
    function test_swap_wstEthToFxSave_happyPath() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.expectEmit(true, true, true, true);
        emit FxSaveWstEthSwapper_v1.FxSaveWstEthSwap(address(this), wstETH, fxSAVE, amountIn, amountIn);

        uint256 amountOut = ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);

        assertEq(amountOut, amountIn, "mock 1:1 fxSAVE out");
        assertEq(IERC20(fxSAVE).balanceOf(address(this)), amountIn);
    }

    /// @notice Final-leg Curve min_dy reverts when minAmountOut exceeds mock output (reverse).
    function test_swap_wstEthToFxSave_revertsOnSlippage() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.expectRevert();
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, amountIn + 1);
    }

    /// @notice A genuinely foreign pair (distinct tokens, but not one of the two supported
    ///         routes) reverts UnsupportedPair. Same-token calls are rejected earlier by the
    ///         envelope's SameToken guard (covered in SwapExecutorTestBase).
    function test_swap_unsupportedPair_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(FxSaveWstEthSwapper_v1.UnsupportedPair.selector, fxSAVE, crvUSD));
        ISwapExecutor(swapperProxy).swap(fxSAVE, crvUSD, amountIn, 0);
    }

    /// @notice Pool and vault allowances are cleared to zero after every forward swap.
    function test_swap_fxSaveToWstEth_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);

        assertEq(IERC20(fxSAVE).allowance(swapperProxy, poolFxSaveScrvUsd), 0);
        assertEq(IERC20(scrvUsdVault).allowance(swapperProxy, scrvUsdVault), 0);
        assertEq(IERC20(crvUSD).allowance(swapperProxy, poolTricryptoLlama), 0);
    }

    /// @notice Pool and vault allowances are cleared to zero after every reverse swap.
    function test_swap_wstEthToFxSave_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);

        assertEq(IERC20(wstETH).allowance(swapperProxy, poolTricryptoLlama), 0);
        assertEq(IERC20(crvUSD).allowance(swapperProxy, scrvUsdVault), 0);
        assertEq(IERC20(scrvUsdVault).allowance(swapperProxy, poolFxSaveScrvUsd), 0);
    }

    /// @notice fromToken pulled from msg.sender; toToken delivered to msg.sender (forward).
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

    /// @notice fromToken pulled from msg.sender; toToken delivered to msg.sender (reverse).
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

    /// @notice A donated scrvUSD-share balance is not swept into the caller's output: the
    ///         forward route consumes only the shares its own leg produced, leaving the
    ///         donation in the swapper.
    function test_swap_fxSaveToWstEth_ignoresDonatedIntermediate() public {
        uint256 amountIn = 1 ether;
        uint256 donation = 0.5 ether;

        // Seed the swapper with scrvUSD vault shares by depositing crvUSD to its address.
        MockERC20(crvUSD).mint(address(this), donation);
        IERC20(crvUSD).approve(scrvUsdVault, donation);
        IERC4626(scrvUsdVault).deposit(donation, swapperProxy);
        assertEq(IERC20(scrvUsdVault).balanceOf(swapperProxy), donation, "donation seeded");

        _mintAndApprove(fxSAVE, swapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);

        // At 1:1 mock rates only the leg's own 1 ether flows through; the donation stays put.
        assertEq(amountOut, amountIn, "donation not swept into output");
        assertEq(IERC20(scrvUsdVault).balanceOf(swapperProxy), donation, "donation untouched");
    }

    /// @notice A donated crvUSD balance is not swept into the caller's output: the reverse
    ///         route deposits only the crvUSD its own leg produced, leaving the donation in
    ///         the swapper.
    function test_swap_wstEthToFxSave_ignoresDonatedIntermediate() public {
        uint256 amountIn = 1 ether;
        uint256 donation = 0.5 ether;

        MockERC20(crvUSD).mint(swapperProxy, donation);
        assertEq(IERC20(crvUSD).balanceOf(swapperProxy), donation, "donation seeded");

        _mintAndApprove(wstETH, swapperProxy, amountIn);
        uint256 amountOut = ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);

        assertEq(amountOut, amountIn, "donation not swept into output");
        assertEq(IERC20(crvUSD).balanceOf(swapperProxy), donation, "donation untouched");
    }

    /// @notice Pool revert on leg 1 is surfaced via PoolCallFailed (forward).
    function test_swap_fxSaveToWstEth_poolRevert_surfacesError() public {
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setShouldRevert(true);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(); // PoolCallFailed wraps "MockFxSaveScrvUsdPool: forced revert"
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
    }

    /// @notice A leg-1 Curve exchange that produces zero scrvUSD shares (forward) reverts
    ///         Token.ZeroInputBalance for the share token — the Curve leg is the failing
    ///         actor, not the vault.
    function test_swap_fxSaveToWstEth_zeroLegOneOutput_reverts() public {
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setRate(0);
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, scrvUsdVault));
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
    }

    /// @notice A leg-1 Curve exchange that produces zero crvUSD (reverse) reverts
    ///         Token.ZeroInputBalance for crvUSD — the Curve leg is the failing actor, not
    ///         the vault.
    function test_swap_wstEthToFxSave_zeroLegOneOutput_reverts() public {
        MockCurvePool(poolTricryptoLlama).setRate(0);
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, crvUSD));
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);
    }

    /// @notice A vault redeem that takes >0 shares but returns zero assets reverts
    ///         VaultRedeemFailed — the vault is the failing actor (forward).
    function test_swap_fxSaveToWstEth_vaultReturnsZeroAssets_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn);

        vm.mockCall(scrvUsdVault, abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode(uint256(0)));
        vm.expectRevert(FxSaveWstEthSwapper_v1.VaultRedeemFailed.selector);
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
        vm.clearMockedCalls();
    }

    /// @notice A vault deposit that takes >0 crvUSD but mints zero shares reverts
    ///         VaultDepositFailed — the vault is the failing actor (reverse).
    function test_swap_wstEthToFxSave_vaultReturnsZeroShares_reverts() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(wstETH, swapperProxy, amountIn);

        vm.mockCall(scrvUsdVault, abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode(uint256(0)));
        vm.expectRevert(FxSaveWstEthSwapper_v1.VaultDepositFailed.selector);
        ISwapExecutor(swapperProxy).swap(wstETH, fxSAVE, amountIn, 0);
        vm.clearMockedCalls();
    }

    /// @notice Re-entrant call from the fxSAVE/scrvUSD pool is blocked by nonReentrant (forward).
    function test_swap_fxSaveToWstEth_reentrancyGuard() public {
        uint256 amountIn = 1 ether;
        _mintAndApprove(fxSAVE, swapperProxy, amountIn * 2);

        bytes memory reentrantCall = abi.encodeCall(ISwapExecutor.swap, (fxSAVE, wstETH, amountIn, 0));
        MockFxSaveScrvUsdPool(poolFxSaveScrvUsd).setReentrantCall(swapperProxy, reentrantCall);

        vm.expectRevert();
        ISwapExecutor(swapperProxy).swap(fxSAVE, wstETH, amountIn, 0);
    }
}
