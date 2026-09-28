#!/usr/bin/env bash
#
# Re-derives hyEUR routeCostRatio terms from live mainnet state.
#
# Routes measured:
#   A) fxSAVE → EURC  (ConfigFxSaveEurcRoute) — Curve crvUSD/USDC + Uni USDC/EURC 0.05%
#   B) wstETH → EURC  (ConfigSwap _wstEthToEurcUniPath) — Uni wstETH/WETH 0.01%
#        + WETH/USDC 0.05% + USDC/EURC 0.05%
#
# HOW TO RUN
# ----------
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:eur
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:eur <block>
#
set -o pipefail

readonly RPC="mainnet"
readonly CFG="src/swap/config/ConfigFxSaveEurcRoute_ETH_mainnet.sol"
readonly CFG_ETH="src/swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol"
readonly QUOTER_V1="0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"
readonly EPSILON_FX=1000000000000000000
readonly SIZE_FX=15000000000000000000000
readonly EPSILON_WST=1000000000000000
readonly SIZE_WST=10000000000000000000

for f in "${CFG}" "${CFG_ETH}"; do
  [[ -f $f ]] || { echo "run from repo root: $f missing" >&2; exit 1; }
done

sol_const() {
  local file=$1 name=$2 value
  value=$(grep -oE "constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*[^;]+" "${file}" | sed -E "s/.*=[[:space:]]*//;s/[[:space:]]//g")
  [[ -n ${value} ]] || { echo "constant ${name} not in ${file}" >&2; exit 1; }
  echo "${value}"
}

uni_path3() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import sys
a,f1,b,f2,c,f3,d=sys.argv[1:8]
def A(x): return x[2:].lower() if x.startswith("0x") else x.lower()
def F(x): return int(x).to_bytes(3,"big").hex()
print("0x"+A(a)+F(f1)+A(b)+F(f2)+A(c)+F(f3)+A(d))
PY
}

POOL_FX=$(sol_const "${CFG}" POOL_FXSAVE_SCRVUSD)
POOL_USD=$(sol_const "${CFG}" POOL_CRVUSD_USDC)
VAULT=$(sol_const "${CFG}" SCRVUSD_VAULT)
USDC=$(sol_const "${CFG}" USDC)
EURC=$(sol_const "${CFG}" EURC)
I_FXSAVE=$(sol_const "${CFG}" POOL2_I_FXSAVE)
J_SCRVUSD=$(sol_const "${CFG}" POOL2_J_SCRVUSD)
I_USDC=$(sol_const "${CFG}" POOL_USD_I_USDC)
J_CRVUSD=$(sol_const "${CFG}" POOL_USD_J_CRVUSD)
FEE_EUR=$(sol_const "${CFG}" UNI_USDC_EURC_FEE)
# Match ConfigSwap_ETH_mainnet._wstEthToEurcUniPath via ETH-route uint24 tiers + EURC fee.
WSTETH=$(sol_const "${CFG_ETH}" WSTETH)
WETH=$(sol_const "${CFG_ETH}" WETH)
FEE_WW=$(sol_const "${CFG_ETH}" UNI_WETH_WSTETH_FEE)
FEE_WU=$(sol_const "${CFG_ETH}" UNI_USDC_WETH_FEE)
PATH_WST_EURC=$(uni_path3 "${WSTETH}" "${FEE_WW}" "${WETH}" "${FEE_WU}" "${USDC}" "${FEE_EUR}" "${EURC}")

BLOCK=${1:-$(cast block-number --rpc-url "${RPC}")}
readonly BLOCK

call() { cast call "$@" --block "${BLOCK}" --rpc-url "${RPC}" 2>/dev/null | awk '{print $1}'; }

fx_to_eurc() {
  local shares crv usdc out
  shares=$(call "${POOL_FX}" "get_dy(int128,int128,uint256)(uint256)" "${I_FXSAVE}" "${J_SCRVUSD}" "$1")
  [[ -z ${shares} ]] && { echo 0; return; }
  crv=$(call "${VAULT}" "previewRedeem(uint256)(uint256)" "${shares}")
  [[ -z ${crv} ]] && { echo 0; return; }
  usdc=$(call "${POOL_USD}" "get_dy(int128,int128,uint256)(uint256)" "${J_CRVUSD}" "${I_USDC}" "${crv}")
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

python3 - "${FEE_FX}" "${FEE_USD}" "${FEE_EUR}" "${FEE_WW}" "${FEE_WU}" \
  "${SIZE_FX}" "${OUT}" "${OUT0}" "${SIZE_WST}" "${OUT_WST}" "${OUT_WST0}" \
  "${EPSILON_FX}" "${EPSILON_WST}" <<'PY'
import sys
(fee_fx, fee_usd, fee_eur, fee_ww, fee_wu,
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
print(f"UNI_WSTETH_WETH_FEE       {scaled(pct_u(fee_ww)):.3e}  {pct_u(fee_ww):.4f}%  (tier {fee_ww})")
print(f"UNI_USDC_WETH_FEE         {scaled(pct_u(fee_wu)):.3e}  {pct_u(fee_wu):.4f}%  (tier {fee_wu})")

print()
print("--- Quotes at size ---")
print(f"15k fxSAVE -> EURC        {out / 1e6:,.2f} EURC   size-impact {imp:+.3f}%")
print(f"10  wstETH -> EURC        {out_wst / 1e6:,.2f} EURC   size-impact {imp_w:+.3f}%")

print()
print("--- Suggested composed ratios ---")
fx = pct_c(fee_fx) + pct_c(fee_usd) + pct_u(fee_eur) + (imp if imp == imp else 0.3)
wst = pct_u(fee_ww) + pct_u(fee_wu) + pct_u(fee_eur) + (imp_w if imp_w == imp_w else 0.3)
print(f"FXSAVE_TO_EURC_ROUTE_COST_RATIO   {scaled(fx):.3e}  {fx:.4f}%")
print(f"WSTETH_TO_EURC_ROUTE_COST_RATIO   {scaled(wst):.3e}  {wst:.4f}%")
print()
print("Write into script/src/config/ConfigSwap_ETH_mainnet.sol after rounding.")
PY
