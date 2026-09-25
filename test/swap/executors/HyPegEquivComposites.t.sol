// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Hy peg-equiv composites (other than FxSaveWstEth, which has its own suite):
// selector-accurate UnsupportedPair, happy-path approvals, and donated-intermediate guards.

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockERC4626Vault} from "@harbor-swap-test-mocks/MockERC4626Vault.sol";
import {MockCurveCryptoPool} from "@harbor-swap-test-mocks/MockCurveCryptoPool.sol";
import {MockCurveStableSwapPool} from "@harbor-swap-test-mocks/MockCurveStableSwapPool.sol";
import {MockFxSaveScrvUsdPool} from "@harbor-swap-test-mocks/MockFxSaveScrvUsdPool.sol";
import {MockUniV3Router} from "@harbor-swap-test-mocks/MockUniV3Router.sol";

import {FxSaveWbtcSwapper_v1} from "@harbor-swap/executors/FxSaveWbtcSwapper_v1.sol";
import {FxSaveLbtcSwapper_v1} from "@harbor-swap/executors/FxSaveLbtcSwapper_v1.sol";
import {FxSaveEurcSwapper_v1} from "@harbor-swap/executors/FxSaveEurcSwapper_v1.sol";
import {WstEthWbtcSwapper_v1} from "@harbor-swap/executors/WstEthWbtcSwapper_v1.sol";
import {WstEthLbtcSwapper_v1} from "@harbor-swap/executors/WstEthLbtcSwapper_v1.sol";
import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {Swapper} from "@harbor-swap-script/contracts/Swapper.sol";

// ─── Harnesses (immutables only — UUPS-safe) ─────────────────────────────────

contract FxSaveWbtcHarness is FxSaveWbtcSwapper_v1 {
    address private immutable _fx;
    address private immutable _wbtcTok;
    address private immutable _crv;
    address private immutable _vault;
    address private immutable _poolFx;
    address private immutable _poolBtc;

    constructor(address fx_, address wbtc_, address crv_, address vault_, address poolFx_, address poolBtc_) {
        _fx = fx_;
        _wbtcTok = wbtc_;
        _crv = crv_;
        _vault = vault_;
        _poolFx = poolFx_;
        _poolBtc = poolBtc_;
    }

    function _fxSave() internal view override returns (address) {
        return _fx;
    }

    function _wbtc() internal view override returns (address) {
        return _wbtcTok;
    }

    function _crvUsd() internal view override returns (address) {
        return _crv;
    }

    function _scrvUsdVault() internal view override returns (address) {
        return _vault;
    }

    function _poolFxSaveScrvUsd() internal view override returns (address) {
        return _poolFx;
    }

    function _poolCrvUsdWbtc() internal view override returns (address) {
        return _poolBtc;
    }
}

contract FxSaveLbtcHarness is FxSaveLbtcSwapper_v1 {
    address private immutable _fx;
    address private immutable _lbtcTok;
    address private immutable _wbtcTok;
    address private immutable _crv;
    address private immutable _vault;
    address private immutable _poolFx;
    address private immutable _poolBtc;

    constructor(
        address router_,
        address fx_,
        address lbtc_,
        address wbtc_,
        address crv_,
        address vault_,
        address poolFx_,
        address poolBtc_
    ) FxSaveLbtcSwapper_v1(router_) {
        _fx = fx_;
        _lbtcTok = lbtc_;
        _wbtcTok = wbtc_;
        _crv = crv_;
        _vault = vault_;
        _poolFx = poolFx_;
        _poolBtc = poolBtc_;
    }

    function _fxSave() internal view override returns (address) {
        return _fx;
    }

    function _lbtc() internal view override returns (address) {
        return _lbtcTok;
    }

    function _wbtc() internal view override returns (address) {
        return _wbtcTok;
    }

    function _crvUsd() internal view override returns (address) {
        return _crv;
    }

    function _scrvUsdVault() internal view override returns (address) {
        return _vault;
    }

    function _poolFxSaveScrvUsd() internal view override returns (address) {
        return _poolFx;
    }

    function _poolCrvUsdWbtc() internal view override returns (address) {
        return _poolBtc;
    }
}

contract FxSaveEurcHarness is FxSaveEurcSwapper_v1 {
    address private immutable _fx;
    address private immutable _eurcTok;
    address private immutable _usdcTok;
    address private immutable _crv;
    address private immutable _vault;
    address private immutable _poolFx;
    address private immutable _poolUsd;

    constructor(
        address router_,
        address fx_,
        address eurc_,
        address usdc_,
        address crv_,
        address vault_,
        address poolFx_,
        address poolUsd_
    ) FxSaveEurcSwapper_v1(router_) {
        _fx = fx_;
        _eurcTok = eurc_;
        _usdcTok = usdc_;
        _crv = crv_;
        _vault = vault_;
        _poolFx = poolFx_;
        _poolUsd = poolUsd_;
    }

    function _fxSave() internal view override returns (address) {
        return _fx;
    }

    function _eurc() internal view override returns (address) {
        return _eurcTok;
    }

    function _usdc() internal view override returns (address) {
        return _usdcTok;
    }

    function _crvUsd() internal view override returns (address) {
        return _crv;
    }

    function _scrvUsdVault() internal view override returns (address) {
        return _vault;
    }

    function _poolFxSaveScrvUsd() internal view override returns (address) {
        return _poolFx;
    }

    function _poolCrvUsdUsdc() internal view override returns (address) {
        return _poolUsd;
    }
}

contract WstEthWbtcHarness is WstEthWbtcSwapper_v1 {
    address private immutable _wst;
    address private immutable _wbtcTok;

    constructor(address router_, address wst_, address wbtc_) WstEthWbtcSwapper_v1(router_) {
        _wst = wst_;
        _wbtcTok = wbtc_;
    }

    function _wstEth() internal view override returns (address) {
        return _wst;
    }

    function _wbtc() internal view override returns (address) {
        return _wbtcTok;
    }

    function _uniPath() internal view override returns (bytes memory) {
        return abi.encodePacked(_wst, uint24(100), address(uint160(1)), uint24(500), _wbtcTok);
    }
}

contract WstEthLbtcHarness is WstEthLbtcSwapper_v1 {
    address private immutable _wst;
    address private immutable _lbtcTok;

    constructor(address router_, address wst_, address lbtc_) WstEthLbtcSwapper_v1(router_) {
        _wst = wst_;
        _lbtcTok = lbtc_;
    }

    function _wstEth() internal view override returns (address) {
        return _wst;
    }

    function _lbtc() internal view override returns (address) {
        return _lbtcTok;
    }

    function _uniPath() internal view override returns (bytes memory) {
        return
            abi.encodePacked(
                _wst,
                uint24(100),
                address(uint160(1)),
                uint24(500),
                address(uint160(2)),
                uint24(100),
                _lbtcTok
            );
    }
}

// ─── Suite ───────────────────────────────────────────────────────────────────

contract HyPegEquivCompositesTest is BaoTest, Swapper {
    function owner() public view override returns (address) {
        return address(this);
    }

    function treasury() public view override returns (address) {
        return address(this);
    }

    function _uniV3RouterAddress() internal view override returns (address) {
        return uniRouter;
    }

    address fxSAVE;
    address wstETH;
    address wbtc;
    address lbtc;
    address eurc;
    address usdc;
    address crvUSD;
    address scrvUsdVault;
    address poolFx;
    address poolBtc;
    address poolUsd;
    address uniRouter;

    address fxSaveWbtc;
    address fxSaveLbtc;
    address fxSaveEurc;
    address wstEthWbtc;
    address wstEthLbtc;

    string constant SALT = "test_hy_peg_composites";

    uint256 constant FX_RATE = 1.0013e18;
    uint256 constant BTC_RATE = 1e10; // 18→8 style scale in fixtures (all 18-dec mocks: use 1e-8-ish)
    uint256 constant UNI_RATE = 1e18;
    uint256 constant USD_RATE = 1e18;

    function setUp() public {
        _ensureBaoFactory();
        _setSaltPrefix(SALT);

        fxSAVE = address(new MockERC20("fxSAVE", "fxSAVE", 18));
        wstETH = address(new MockERC20("wstETH", "wstETH", 18));
        wbtc = address(new MockERC20("WBTC", "WBTC", 18));
        lbtc = address(new MockERC20("LBTC", "LBTC", 18));
        eurc = address(new MockERC20("EURC", "EURC", 18));
        usdc = address(new MockERC20("USDC", "USDC", 18));
        crvUSD = address(new MockERC20("crvUSD", "crvUSD", 18));

        scrvUsdVault = address(new MockERC4626Vault(IERC20(crvUSD), "scrvUSD", "scrvUSD"));
        MockERC20(crvUSD).mint(address(this), 1000 ether);
        IERC20(crvUSD).approve(scrvUsdVault, 1000 ether);
        IERC4626(scrvUsdVault).deposit(1000 ether, address(this));
        MockERC4626Vault(scrvUsdVault).addYield(100 ether);

        poolFx = address(new MockFxSaveScrvUsdPool(fxSAVE, IERC4626(scrvUsdVault)));
        MockFxSaveScrvUsdPool(poolFx).setRate(FX_RATE);

        poolBtc = address(new MockCurveCryptoPool());
        MockCurveCryptoPool(payable(poolBtc)).setCoin(0, crvUSD);
        MockCurveCryptoPool(payable(poolBtc)).setCoin(1, wbtc);
        MockCurveCryptoPool(payable(poolBtc)).setRate(BTC_RATE);

        poolUsd = address(new MockCurveStableSwapPool());
        MockCurveStableSwapPool(poolUsd).setCoin(0, usdc);
        MockCurveStableSwapPool(poolUsd).setCoin(1, crvUSD);
        MockCurveStableSwapPool(poolUsd).setRate(USD_RATE);

        uniRouter = address(new MockUniV3Router());
        MockUniV3Router(uniRouter).setRate(UNI_RATE);

        DeploymentTypes.State memory state = DeploymentState.fresh(SALT, "test");
        state.baoFactory = baoFactory();
        deployFxSaveWbtcSwapper(state);
        deployFxSaveLbtcSwapper(state);
        deployFxSaveEurcSwapper(state);
        deployWstEthWbtcSwapper(state);
        deployWstEthLbtcSwapper(state);
        fxSaveWbtc = _predictAddress("fxSaveWbtcSwapper");
        fxSaveLbtc = _predictAddress("fxSaveLbtcSwapper");
        fxSaveEurc = _predictAddress("fxSaveEurcSwapper");
        wstEthWbtc = _predictAddress("wstEthWbtcSwapper");
        wstEthLbtc = _predictAddress("wstEthLbtcSwapper");
    }

    function deployFxSaveWbtcSwapperImplementation() internal override returns (address) {
        return address(new FxSaveWbtcHarness(fxSAVE, wbtc, crvUSD, scrvUsdVault, poolFx, poolBtc));
    }

    function deployFxSaveLbtcSwapperImplementation(address router_) internal override returns (address) {
        return address(new FxSaveLbtcHarness(router_, fxSAVE, lbtc, wbtc, crvUSD, scrvUsdVault, poolFx, poolBtc));
    }

    function deployFxSaveEurcSwapperImplementation(address router_) internal override returns (address) {
        return address(new FxSaveEurcHarness(router_, fxSAVE, eurc, usdc, crvUSD, scrvUsdVault, poolFx, poolUsd));
    }

    function deployWstEthWbtcSwapperImplementation(address router_) internal override returns (address) {
        return address(new WstEthWbtcHarness(router_, wstETH, wbtc));
    }

    function deployWstEthLbtcSwapperImplementation(address router_) internal override returns (address) {
        return address(new WstEthLbtcHarness(router_, wstETH, lbtc));
    }

    function _mintApprove(address token, address spender, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(spender, amount);
    }

    function _forwardWbtcQuote(uint256 amountIn) internal view returns (uint256 crvUsdOut, uint256 wbtcOut) {
        uint256 minted = (amountIn * MockFxSaveScrvUsdPool(poolFx).rate()) / 1e18;
        uint256 shares = IERC4626(scrvUsdVault).previewDeposit(minted);
        crvUsdOut = Math.mulDiv(
            shares,
            IERC4626(scrvUsdVault).totalAssets() + minted + 1,
            IERC20(scrvUsdVault).totalSupply() + shares + 1
        );
        wbtcOut = (crvUsdOut * MockCurveCryptoPool(payable(poolBtc)).rate()) / 1e18;
    }

    // ── UnsupportedPair (selector-accurate) ──────────────────────────────────

    function test_unsupportedPair_fxSaveWbtc() public {
        _mintApprove(fxSAVE, fxSaveWbtc, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FxSaveWbtcSwapper_v1.UnsupportedPair.selector, fxSAVE, wstETH));
        ISwapExecutor(fxSaveWbtc).swap(fxSAVE, wstETH, 1 ether, 0);
    }

    function test_unsupportedPair_fxSaveLbtc() public {
        _mintApprove(fxSAVE, fxSaveLbtc, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FxSaveLbtcSwapper_v1.UnsupportedPair.selector, fxSAVE, wbtc));
        ISwapExecutor(fxSaveLbtc).swap(fxSAVE, wbtc, 1 ether, 0);
    }

    function test_unsupportedPair_fxSaveEurc() public {
        _mintApprove(eurc, fxSaveEurc, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FxSaveEurcSwapper_v1.UnsupportedPair.selector, eurc, fxSAVE));
        ISwapExecutor(fxSaveEurc).swap(eurc, fxSAVE, 1 ether, 0);
    }

    function test_unsupportedPair_wstEthWbtc() public {
        _mintApprove(wbtc, wstEthWbtc, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(WstEthWbtcSwapper_v1.UnsupportedPair.selector, wbtc, wstETH));
        ISwapExecutor(wstEthWbtc).swap(wbtc, wstETH, 1 ether, 0);
    }

    function test_unsupportedPair_wstEthLbtc() public {
        _mintApprove(lbtc, wstEthLbtc, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(WstEthLbtcSwapper_v1.UnsupportedPair.selector, lbtc, wstETH));
        ISwapExecutor(wstEthLbtc).swap(lbtc, wstETH, 1 ether, 0);
    }

    // ── Happy path + approvals ───────────────────────────────────────────────

    function test_fxSaveWbtc_happyPath_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintApprove(fxSAVE, fxSaveWbtc, amountIn);
        (, uint256 expected) = _forwardWbtcQuote(amountIn);

        uint256 out = ISwapExecutor(fxSaveWbtc).swap(fxSAVE, wbtc, amountIn, 0);
        assertEq(out, expected);
        assertEq(IERC20(fxSAVE).allowance(fxSaveWbtc, poolFx), 0);
        assertEq(IERC20(crvUSD).allowance(fxSaveWbtc, poolBtc), 0);
    }

    function test_fxSaveWbtc_ignoresDonatedShares() public {
        uint256 donation = 0.5 ether;
        MockERC20(crvUSD).mint(address(this), donation);
        IERC20(crvUSD).approve(scrvUsdVault, donation);
        IERC4626(scrvUsdVault).deposit(donation, fxSaveWbtc);
        uint256 donationShares = IERC20(scrvUsdVault).balanceOf(fxSaveWbtc);

        uint256 amountIn = 1 ether;
        _mintApprove(fxSAVE, fxSaveWbtc, amountIn);
        (, uint256 expected) = _forwardWbtcQuote(amountIn);
        uint256 out = ISwapExecutor(fxSaveWbtc).swap(fxSAVE, wbtc, amountIn, 0);

        assertEq(out, expected);
        assertEq(IERC20(scrvUsdVault).balanceOf(fxSaveWbtc), donationShares);
    }

    function test_fxSaveLbtc_happyPath_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintApprove(fxSAVE, fxSaveLbtc, amountIn);
        (, uint256 wbtcMid) = _forwardWbtcQuote(amountIn);
        uint256 expected = (wbtcMid * MockUniV3Router(uniRouter).rate()) / 1e18;

        uint256 out = ISwapExecutor(fxSaveLbtc).swap(fxSAVE, lbtc, amountIn, 0);
        assertEq(out, expected);
        assertEq(IERC20(fxSAVE).allowance(fxSaveLbtc, poolFx), 0);
        assertEq(IERC20(crvUSD).allowance(fxSaveLbtc, poolBtc), 0);
        assertEq(IERC20(wbtc).allowance(fxSaveLbtc, uniRouter), 0);
    }

    function test_fxSaveEurc_happyPath_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintApprove(fxSAVE, fxSaveEurc, amountIn);

        uint256 minted = (amountIn * MockFxSaveScrvUsdPool(poolFx).rate()) / 1e18;
        uint256 shares = IERC4626(scrvUsdVault).previewDeposit(minted);
        uint256 crvOut = Math.mulDiv(
            shares,
            IERC4626(scrvUsdVault).totalAssets() + minted + 1,
            IERC20(scrvUsdVault).totalSupply() + shares + 1
        );
        uint256 usdcOut = (crvOut * MockCurveStableSwapPool(poolUsd).rate()) / 1e18;
        uint256 expected = (usdcOut * MockUniV3Router(uniRouter).rate()) / 1e18;

        uint256 out = ISwapExecutor(fxSaveEurc).swap(fxSAVE, eurc, amountIn, 0);
        assertEq(out, expected);
        assertEq(IERC20(fxSAVE).allowance(fxSaveEurc, poolFx), 0);
        assertEq(IERC20(crvUSD).allowance(fxSaveEurc, poolUsd), 0);
        assertEq(IERC20(usdc).allowance(fxSaveEurc, uniRouter), 0);
    }

    function test_wstEthWbtc_happyPath_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintApprove(wstETH, wstEthWbtc, amountIn);
        uint256 expected = (amountIn * MockUniV3Router(uniRouter).rate()) / 1e18;

        uint256 out = ISwapExecutor(wstEthWbtc).swap(wstETH, wbtc, amountIn, 0);
        assertEq(out, expected);
        assertEq(IERC20(wstETH).allowance(wstEthWbtc, uniRouter), 0);
    }

    function test_wstEthLbtc_happyPath_approvalsCleared() public {
        uint256 amountIn = 1 ether;
        _mintApprove(wstETH, wstEthLbtc, amountIn);
        uint256 expected = (amountIn * MockUniV3Router(uniRouter).rate()) / 1e18;

        uint256 out = ISwapExecutor(wstEthLbtc).swap(wstETH, lbtc, amountIn, 0);
        assertEq(out, expected);
        assertEq(IERC20(wstETH).allowance(wstEthLbtc, uniRouter), 0);
    }
}
