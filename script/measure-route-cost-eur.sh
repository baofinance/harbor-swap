#!/usr/bin/env bash
#
# Re-derives hyEUR routeCostRatio terms from live mainnet state.
#
# Routes measured:
#   A) fxSAVE → EURC  (ConfigFxSaveEurcRoute) — Curve crvUSD/USDC + Uni USDC/EURC 0.05%
#   B) wstETH → EURC  (ConfigSwap _wstEthToEurcUniPath) — Uni wstETH/USDC 0.05% + USDC/EURC 0.05%
#
# HOW TO RUN
# ----------
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:eur
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:eur <block>
#
set -o pipefail

readonly RPC="mainnet"
readonly CFG="src/swap/config/ConfigFxSaveEurcRoute_ETH_mainnet.sol"
readonly QUOTER_V1="0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"
readonly WSTETH="0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
readonly EPSILON_FX=1000000000000000000
readonly SIZE_FX=15000000000000000000000
readonly EPSILON_WST=1000000000000000
readonly SIZE_WST=10000000000000000000

[[ -f ${CFG} ]] || { echo "run from repo root: ${CFG} missing" >&2; exit 1; }

sol_const() {
  local name=$1 value
  value=$(grep -oE "constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*[^;]+" "${CFG}" | sed -E "s/.*=[[:space:]]*//;s/[[:space:]]//g")
  [[ -n ${value} ]] || { echo "constant ${name} not in ${CFG}" >&2; exit 1; }
  echo "${value}"
}

uni_path2() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys
a,f1,b,f2,c=sys.argv[1:6]
def A(x): return x[2:].lower() if x.startswith("0x") else x.lower()
def F(x): return int(x).to_bytes(3,"big").hex()
print("0x"+A(a)+F(f1)+A(b)+F(f2)+A(c))
PY
}

POOL_FX=$(sol_const POOL_FXSAVE_SCRVUSD)
POOL_USD=$(sol_const POOL_CRVUSD_USDC)
VAULT=$(sol_const SCRVUSD_VAULT)
USDC=$(sol_const USDC)
EURC=$(sol_const EURC)
FEE_EUR=$(sol_const UNI_USDC_EURC_FEE)
PATH_WST_EURC=$(uni_path2 "${WSTETH}" 500 "${USDC}" "${FEE_EUR}" "${EURC}")

BLOCK=${1:-$(cast block-number --rpc-url "${RPC}")}
readonly BLOCK

call() { cast call "$@" --block "${BLOCK}" --rpc-url "${RPC}" 2>/dev/null | awk '{print $1}'; }

fx_to_eurc() {
  local shares crv usdc out
  shares=$(call "${POOL_FX}" "get_dy(int128,int128,uint256)(uint256)" 0 1 "$1")
  [[ -z ${shares} ]] && { echo 0; return; }
  crv=$(call "${VAULT}" "previewRedeem(uint256)(uint256)" "${shares}")
  [[ -z ${crv} ]] && { echo 0; return; }
  usdc=$(call "${POOL_USD}" "get_dy(int128,int128,uint256)(uint256)" 1 0 "${crv}")
  [[ -z ${usdc} ]] && { echo 0; return; }
  out=$(call "${QUOTER_V1}" "quoteExactInputSingle(address,address,uint24,uint256,uint160)(uint256)" \
    "${USDC}" "${EURC}" "${FEE_EUR}" "${usdc}" 0)
  echo "${out:-0}"
}

echo "=== hyEUR route cost, measured at block ${BLOCK} ==="

FEE_FX=$(call "${POOL_FX}" "fee()(uint256)")
FEE_USD=$(call "${POOL_USD}" "fee()(uint256)")
OUT=$(fx_to_eurc "${SIZE_FX}")
OUT0=$(fx_to_eurc "${EPSILON_FX}")
OUT_WST=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_WST_EURC}" "${SIZE_WST}")
OUT_WST0=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_WST_EURC}" "${EPSILON_WST}")

python3 - "${FEE_FX}" "${FEE_USD}" "${FEE_EUR}" \
  "${SIZE_FX}" "${OUT}" "${OUT0}" "${SIZE_WST}" "${OUT_WST}" "${OUT_WST0}" \
  "${EPSILON_FX}" "${EPSILON_WST}" <<'PY'
import sys
(fee_fx, fee_usd, fee_eur,
 size_fx, out, out0, size_wst, out_wst, out_wst0,
 eps_fx, eps_wst) = (int(x) for x in sys.argv[1:])

def pct_c(f): return f / 1e8
def pct_u(t): return t / 1e4
def scaled(p): return p / 100 * 1e18
def impact(size, out, eps, eps_out):
    if out == 0 or eps_out == 0: return float("nan")
    return (1 - (out / size) / (eps_out / eps)) * 100

imp = impact(size_fx, out, eps_fx, out0)
imp_w = impact(size_wst, out_wst, eps_wst, out_wst0)

print()
print("--- Venue fees ---")
print(f"FXSAVE_SCRVUSD_POOL_FEE   {scaled(pct_c(fee_fx)):.3e}  {pct_c(fee_fx):.4f}%")
print(f"CRVUSD_USDC_POOL_FEE      {scaled(pct_c(fee_usd)):.3e}  {pct_c(fee_usd):.4f}%")
print(f"UNI_USDC_EURC_FEE         {scaled(pct_u(fee_eur)):.3e}  {pct_u(fee_eur):.4f}%")
print(f"UNI_WSTETH_USDC_FEE       {scaled(0.05):.3e}  0.0500%  (tier 500)")

print()
print("--- Quotes at size ---")
print(f"15k fxSAVE -> EURC        {out / 1e6:,.2f} EURC   size-impact {imp:+.3f}%")
print(f"10  wstETH -> EURC        {out_wst / 1e6:,.2f} EURC   size-impact {imp_w:+.3f}%")

print()
print("--- Suggested composed ratios ---")
fx = pct_c(fee_fx) + pct_c(fee_usd) + pct_u(fee_eur) + (imp if imp == imp else 0.3)
wst = 0.05 + pct_u(fee_eur) + (imp_w if imp_w == imp_w else 0.3)
print(f"FXSAVE_TO_EURC_ROUTE_COST_RATIO   {scaled(fx):.3e}  {fx:.4f}%")
print(f"WSTETH_TO_EURC_ROUTE_COST_RATIO   {scaled(wst):.3e}  {wst:.4f}%")
print()
print("Write into script/src/config/ConfigSwap_ETH_mainnet.sol after rounding.")
PY
