#!/usr/bin/env bash
#
# Placeholder for hyUSD / USD-native routeCostRatio measurement.
#
# STATUS
# ------
# No dedicated USD peg-equiv composite executor exists yet beyond the shared fxSAVE
# legs already measured by `yarn measure:route-cost:eth` (fxSAVE is the USD-side
# wrapped collateral on ETH mainnet). When a USD-specific route lands (e.g. a new
# Config*UsdRoute + executor), expand this script the same way as eth/btc/eur:
#
#   1. Read venue constants from the route config library
#   2. Quote fees (static Curve / Uni tiers)
#   3. Measure size impact at 5% of shallow-side depth (or a fixed keeper size)
#   4. Print composed `*_ROUTE_COST_RATIO` lines for ConfigSwap_ETH_mainnet.sol
#
# Until then:
#   - hyUSD remint / reverse flow uses Velora `redistribute`, not a direct USD executor
#   - fxSAVE ↔ wstETH reverse is covered by measure:route-cost:eth
#
# HOW TO RUN
# ----------
#   yarn measure:route-cost:usd
#
set -euo pipefail

echo "=== hyUSD / USD route cost — not yet instrumented ==="
echo
echo "No Config*UsdRoute_ETH_mainnet (or peer) is wired for a dedicated USD composite."
echo "Use:"
echo "  yarn measure:route-cost:eth   # fxSAVE ↔ wstETH (fxSAVE is the USD-side vault token)"
echo "  yarn measure:route-cost:btc   # hyBTC wrappers"
echo "  yarn measure:route-cost:eur   # hyEUR"
echo
echo "When a USD route is added, replace this stub with a real measure script and"
echo "point package.json measure:route-cost:usd at it."
exit 0
