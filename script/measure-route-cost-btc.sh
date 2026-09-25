#!/usr/bin/env bash
#
# Re-derives hyBTC routeCostRatio terms from live mainnet state.
#
# Routes measured:
#   A) fxSAVE ↔ WBTC   (ConfigFxSaveWbtcRoute)  — Curve TwoCrypto after scrvUSD
#   B) fxSAVE → LBTC   (ConfigFxSaveLbtcRoute)  — A + Uni WBTC/LBTC 0.01%
#   C) wstETH → WBTC   (ConfigWstEthWbtcRoute)  — Uni multi-hop
#   D) wstETH → LBTC   (ConfigWstEthLbtcRoute)  — Uni three-hop
#
# HOW TO RUN
# ----------
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:btc
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:btc <block>
#
set -o pipefail

readonly RPC="mainnet"
readonly CFG_WBTC="src/swap/config/ConfigFxSaveWbtcRoute_ETH_mainnet.sol"
readonly CFG_LBTC="src/swap/config/ConfigFxSaveLbtcRoute_ETH_mainnet.sol"
readonly CFG_WST_WBTC="src/swap/config/ConfigWstEthWbtcRoute_ETH_mainnet.sol"
readonly CFG_WST_LBTC="src/swap/config/ConfigWstEthLbtcRoute_ETH_mainnet.sol"
readonly QUOTER_V1="0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"
readonly EPSILON_FX=1000000000000000000 # 1 fxSAVE
readonly EPSILON_WST=1000000000000000   # 0.001 wstETH
readonly SIZE_FX=15000000000000000000000 # 15k fxSAVE
readonly SIZE_WST=10000000000000000000   # 10 wstETH

for f in "${CFG_WBTC}" "${CFG_LBTC}" "${CFG_WST_WBTC}" "${CFG_WST_LBTC}"; do
  [[ -f $f ]] || { echo "run from repo root: $f missing" >&2; exit 1; }
done

sol_const() {
  local file=$1 name=$2 value
  value=$(grep -oE "constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*[^;]+" "${file}" | sed -E "s/.*=[[:space:]]*//;s/[[:space:]]//g")
  [[ -n ${value} ]] || { echo "constant ${name} not in ${file}" >&2; exit 1; }
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

uni_path3() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import sys
a,f1,b,f2,c,f3,d=sys.argv[1:8]
def A(x): return x[2:].lower() if x.startswith("0x") else x.lower()
def F(x): return int(x).to_bytes(3,"big").hex()
print("0x"+A(a)+F(f1)+A(b)+F(f2)+A(c)+F(f3)+A(d))
PY
}

POOL_FX=$(sol_const "${CFG_WBTC}" POOL_FXSAVE_SCRVUSD)
POOL_BTC=$(sol_const "${CFG_WBTC}" POOL_CRVUSD_WBTC)
VAULT=$(sol_const "${CFG_WBTC}" SCRVUSD_VAULT)
WBTC=$(sol_const "${CFG_WBTC}" WBTC)
LBTC=$(sol_const "${CFG_LBTC}" LBTC)
WSTETH=$(sol_const "${CFG_WST_WBTC}" WSTETH)
WETH=$(sol_const "${CFG_WST_WBTC}" WETH)
I_FX=0; J_SCRV=1; I_CRV=0; J_WBTC=1
FEE_WRAP=$(sol_const "${CFG_LBTC}" UNI_WBTC_LBTC_FEE)
FEE_WW=$(sol_const "${CFG_WST_WBTC}" UNI_WSTETH_WETH_FEE)
FEE_WB=$(sol_const "${CFG_WST_WBTC}" UNI_WETH_WBTC_FEE)
PATH_WST_WBTC=$(uni_path2 "${WSTETH}" "${FEE_WW}" "${WETH}" "${FEE_WB}" "${WBTC}")
PATH_WST_LBTC=$(uni_path3 "${WSTETH}" "${FEE_WW}" "${WETH}" "${FEE_WB}" "${WBTC}" "${FEE_WRAP}" "${LBTC}")

BLOCK=${1:-$(cast block-number --rpc-url "${RPC}")}
readonly BLOCK

call() { cast call "$@" --block "${BLOCK}" --rpc-url "${RPC}" 2>/dev/null | awk '{print $1}'; }

fx_to_wbtc() {
  local shares crv out
  shares=$(call "${POOL_FX}" "get_dy(int128,int128,uint256)(uint256)" ${I_FX} ${J_SCRV} "$1")
  [[ -z ${shares} ]] && { echo 0; return; }
  crv=$(call "${VAULT}" "previewRedeem(uint256)(uint256)" "${shares}")
  [[ -z ${crv} ]] && { echo 0; return; }
  out=$(call "${POOL_BTC}" "get_dy(uint256,uint256,uint256)(uint256)" ${I_CRV} ${J_WBTC} "${crv}")
  echo "${out:-0}"
}

fx_to_lbtc() {
  local wbtc
  wbtc=$(fx_to_wbtc "$1")
  [[ ${wbtc} == 0 || -z ${wbtc} ]] && { echo 0; return; }
  call "${QUOTER_V1}" "quoteExactInputSingle(address,address,uint24,uint256,uint160)(uint256)" \
    "${WBTC}" "${LBTC}" "${FEE_WRAP}" "${wbtc}" 0
}

echo "=== hyBTC route cost, measured at block ${BLOCK} ==="

FEE_FX=$(call "${POOL_FX}" "fee()(uint256)")
FEE_BTC=$(call "${POOL_BTC}" "fee()(uint256)")
OUT_WBTC=$(fx_to_wbtc "${SIZE_FX}")
OUT_WBTC0=$(fx_to_wbtc "${EPSILON_FX}")
OUT_LBTC=$(fx_to_lbtc "${SIZE_FX}")
OUT_WST_WBTC=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_WST_WBTC}" "${SIZE_WST}")
OUT_WST_WBTC0=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_WST_WBTC}" "${EPSILON_WST}")
OUT_WST_LBTC=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_WST_LBTC}" "${SIZE_WST}")

python3 - "${FEE_FX}" "${FEE_BTC}" "${FEE_WRAP}" "${FEE_WW}" "${FEE_WB}" \
  "${SIZE_FX}" "${OUT_WBTC}" "${OUT_WBTC0}" "${OUT_LBTC}" \
  "${SIZE_WST}" "${OUT_WST_WBTC}" "${OUT_WST_WBTC0}" "${OUT_WST_LBTC}" \
  "${EPSILON_FX}" "${EPSILON_WST}" <<'PY'
import sys
vals = [int(x) for x in sys.argv[1:]]
(fee_fx, fee_btc, fee_wrap, fee_ww, fee_wb,
 size_fx, out_wbtc, out_wbtc0, out_lbtc,
 size_wst, out_wst_wbtc, out_wst_wbtc0, out_wst_lbtc,
 eps_fx, eps_wst) = vals

def pct_curve(f): return f / 1e8
def pct_uni(t): return t / 1e4
def scaled(p): return p / 100 * 1e18
def impact(size, out, eps, eps_out):
    if out == 0 or eps_out == 0: return float("nan")
    return (1 - (out / size) / (eps_out / eps)) * 100

imp_fx = impact(size_fx, out_wbtc, eps_fx, out_wbtc0)
imp_wst = impact(size_wst, out_wst_wbtc, eps_wst, out_wst_wbtc0)

print()
print("--- Venue fees ---")
print(f"FXSAVE_SCRVUSD_POOL_FEE   {scaled(pct_curve(fee_fx)):.3e}  {pct_curve(fee_fx):.4f}%")
print(f"CRVUSD_WBTC fee (live)    {scaled(pct_curve(fee_btc)):.3e}  {pct_curve(fee_btc):.4f}%  (config uses ~1% provisional)")
print(f"UNI_WBTC_LBTC_FEE         {scaled(pct_uni(fee_wrap)):.3e}  {pct_uni(fee_wrap):.4f}%")
print(f"UNI_WSTETH_WETH_FEE       {scaled(pct_uni(fee_ww)):.3e}  {pct_uni(fee_ww):.4f}%")
print(f"UNI_WETH_WBTC_FEE         {scaled(pct_uni(fee_wb)):.3e}  {pct_uni(fee_wb):.4f}%")

print()
print("--- Quotes at size ---")
print(f"15k fxSAVE -> WBTC        {out_wbtc / 1e8:.6f} WBTC   size-impact {imp_fx:+.3f}%")
print(f"15k fxSAVE -> LBTC        {out_lbtc / 1e8:.6f} LBTC")
print(f"10  wstETH -> WBTC        {out_wst_wbtc / 1e8:.6f} WBTC   size-impact {imp_wst:+.3f}%")
print(f"10  wstETH -> LBTC        {out_wst_lbtc / 1e8:.6f} LBTC")

print()
print("--- Suggested composed ratios (fees + measured impact; round before writing) ---")
# Use live TwoCrypto fee when available; fall back message if zero
btc_fee = pct_curve(fee_btc) if fee_btc else 1.0
fx_wbtc = pct_curve(fee_fx) + btc_fee + (imp_fx if imp_fx == imp_fx else 0.5)
fx_lbtc = fx_wbtc + pct_uni(fee_wrap)
wst_wbtc = pct_uni(fee_ww) + pct_uni(fee_wb) + (imp_wst if imp_wst == imp_wst else 0.2)
wst_lbtc = wst_wbtc + pct_uni(fee_wrap)
print(f"FXSAVE_TO_WBTC_ROUTE_COST_RATIO   {scaled(fx_wbtc):.3e}  {fx_wbtc:.4f}%")
print(f"FXSAVE_TO_LBTC_ROUTE_COST_RATIO   {scaled(fx_lbtc):.3e}  {fx_lbtc:.4f}%")
print(f"WSTETH_TO_WBTC_ROUTE_COST_RATIO   {scaled(wst_wbtc):.3e}  {wst_wbtc:.4f}%")
print(f"WSTETH_TO_LBTC_ROUTE_COST_RATIO   {scaled(wst_lbtc):.3e}  {wst_lbtc:.4f}%")
print()
print("Write into script/src/config/ConfigSwap_ETH_mainnet.sol after rounding.")
PY
