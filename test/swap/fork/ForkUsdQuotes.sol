// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {console2 as console} from "forge-std/console2.sol";

import {ConfigFxSaveWstEthRoute_ETH_mainnet as WstCfg} from "@harbor-swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol";

/// @dev TEMP fork-only USD notional helpers for amount-check logs. Not for production.
///      Feeds: Chainlink ETH/USD, BTC/USD, EUR/USD. wstETH hops stETH rate × ETH/USD.
///      fxSAVE hops Curve→vault→crvUSD then treats crvUSD/USDC as $1 (fxUSD = USDC feed).
///      LBTC priced 1:1 with WBTC via BTC/USD. All USD values are 6-dec ($1 = 1e6).
///      Visible with `forge test -vv` (Forge hides console.log below verbosity 2).
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

interface IWstETHRate {
    function getStETHByWstETH(uint256 amount) external view returns (uint256);
}

interface ICurveStableSwapViewUsd {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

abstract contract ForkUsdQuotes {
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address internal constant CHAINLINK_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;

    /// @return price 1e8-scaled USD per 1 whole unit (Chainlink convention).
    function _feedUsd1e8(address feed) internal view returns (uint256 price) {
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "bad feed");
        uint8 dec = IAggregatorV3(feed).decimals();
        price = uint256(answer);
        if (dec < 8) price *= 10 ** (8 - dec);
        else if (dec > 8) price /= 10 ** (dec - 8);
    }

    function _ethUsd6(uint256 weiAmt) internal view returns (uint256) {
        return (weiAmt * _feedUsd1e8(CHAINLINK_ETH_USD)) / 1e20; // wei * 1e8 / 1e18 → 1e6
    }

    function _wstEthUsd6(uint256 wstEthAmt) internal view returns (uint256) {
        uint256 stEth = IWstETHRate(WstCfg.WSTETH).getStETHByWstETH(wstEthAmt);
        return _ethUsd6(stEth); // stETH ≈ ETH for USD
    }

    function _wethUsd6(uint256 wethAmt) internal view returns (uint256) {
        return _ethUsd6(wethAmt);
    }

    function _btcUsd6(uint256 btc8dec) internal view returns (uint256) {
        return (btc8dec * _feedUsd1e8(CHAINLINK_BTC_USD)) / 1e10; // 8-dec * 1e8 / 1e10 → 1e6
    }

    function _wbtcUsd6(uint256 wbtcAmt) internal view returns (uint256) {
        return _btcUsd6(wbtcAmt);
    }

    function _lbtcUsd6(uint256 lbtcAmt) internal view returns (uint256) {
        return _btcUsd6(lbtcAmt); // hop: LBTC ≈ WBTC ≈ BTC
    }

    function _eurcUsd6(uint256 eurc6dec) internal view returns (uint256) {
        return (eurc6dec * _feedUsd1e8(CHAINLINK_EUR_USD)) / 1e8;
    }

    function _usdcUsd6(uint256 usdc6dec) internal pure returns (uint256) {
        return usdc6dec; // fxUSD = USDC feed ($1)
    }

    function _crvUsdUsd6(uint256 crvUsd18) internal pure returns (uint256) {
        return crvUsd18 / 1e12;
    }

    /// @notice Hop fxSAVE → scrvUSD shares → crvUSD, then $1 (USDC feed).
    function _fxSaveUsd6(uint256 fxSaveAmt) internal view returns (uint256) {
        uint256 shares = ICurveStableSwapViewUsd(WstCfg.POOL_FXSAVE_SCRVUSD).get_dy(
            WstCfg.POOL2_I_FXSAVE,
            WstCfg.POOL2_J_SCRVUSD,
            fxSaveAmt
        );
        uint256 crvUsd = IERC4626(WstCfg.SCRVUSD_VAULT).previewRedeem(shares);
        return _crvUsdUsd6(crvUsd);
    }

    function _sharesUsd6(uint256 scrvUsdShares) internal view returns (uint256) {
        uint256 crvUsd = IERC4626(WstCfg.SCRVUSD_VAULT).previewRedeem(scrvUsdShares);
        return _crvUsdUsd6(crvUsd);
    }

    /// @dev TEMP debug — remove after manual amount check. USD6: $1 = 1e6.
    ///      usdDiffPct = (out-in)/in as a percent string with 4 decimals (e.g. "-0.0073%").
    function _logExecuted(
        string memory inLabel,
        uint256 amountIn,
        uint256 inUsd6,
        string memory outLabel,
        uint256 amountOut,
        uint256 outUsd6,
        uint256 quoted,
        uint256 quotedUsd6
    ) internal pure {
        console.log("--- executed swap ---");
        console.log(inLabel, amountIn);
        console.log("amountInUSDvalue ", inUsd6);
        console.log(outLabel, amountOut);
        console.log("amountOutUSDvalue", outUsd6);
        console.log("quoted           ", quoted);
        console.log("quotedUSDvalue   ", quotedUsd6);
        console.log("usdDiffPct       ", _formatUsdDiffPct(inUsd6, outUsd6));
    }

    /// @dev (out-in)/in * 1e6 → percent with 4 decimals (÷10000).
    function _formatUsdDiffPct(uint256 inUsd6, uint256 outUsd6) internal pure returns (string memory) {
        int256 ppm = (int256(outUsd6) - int256(inUsd6)) * 1_000_000 / int256(inUsd6);
        bool neg = ppm < 0;
        uint256 absPpm = uint256(neg ? -ppm : ppm);
        uint256 whole = absPpm / 10_000;
        uint256 frac = absPpm % 10_000;
        return string.concat(neg ? "-" : "", Strings.toString(whole), ".", _pad4(frac), "%");
    }

    function _pad4(uint256 n) internal pure returns (string memory) {
        if (n >= 1000) return Strings.toString(n);
        if (n >= 100) return string.concat("0", Strings.toString(n));
        if (n >= 10) return string.concat("00", Strings.toString(n));
        return string.concat("000", Strings.toString(n));
    }
}
