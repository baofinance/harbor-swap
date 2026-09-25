#!/usr/bin/env bash
#
# Re-derives the fxSAVE <-> wstETH `routeCostRatio` constants from live mainnet state.
#
# Route (see ConfigFxSaveWstEthRoute_ETH_mainnet):
#   fxSAVE → scrvUSD → redeem → crvUSD → USDC (Curve) → WETH → wstETH (UniV3)
#
# Sections:
#   1  static fxSAVE/scrvUSD pool fee + depth   -> FXSAVE_SCRVUSD_POOL_FEE
#   2  static mid-leg fees                      -> CRVUSD_USDC_POOL_FEE, UNI_*_FEE
#   3  price impact vs trade size               -> *_EXPECTED_SLIPPAGE
#   4  composed ratios
#
# HOW TO RUN
# ----------
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:eth
#   MAINNET_RPC_URL=https://... yarn measure:route-cost:eth 25682862
#
# Run from the repository root. Needs `cast` and `python3`.
#
set -o pipefail

readonly RPC="mainnet"
readonly ROUTE_CONFIG="src/swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol"
readonly QUOTER_V1="0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"
readonly SHALLOW_SIDE_PERCENT=5
readonly EPSILON=1000000000000000 # 0.001 token

if [[ ! -f ${ROUTE_CONFIG} ]]; then
  echo "run from the repository root: ${ROUTE_CONFIG} not found" >&2
  exit 1
fi

big() {
  python3 -c "print($1)"
}

sol_const() {
  local name=$1 value
  value=$(grep -oE "constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*[^;]+" "${ROUTE_CONFIG}" | sed -E "s/.*=[[:space:]]*//;s/[[:space:]]//g")
  if [[ -z ${value} ]]; then
    echo "constant ${name} not found in ${ROUTE_CONFIG}" >&2
    exit 1
  fi
  echo "${value}"
}

# Encode UniV3 path from sol_const fee tiers (lowercase hex, no 0x).
uni_path() {
  local a=$1 fee1=$2 b=$3 fee2=$4 c=$5
  python3 - "${a}" "${fee1}" "${b}" "${fee2}" "${c}" <<'PY'
import sys
a, fee1, b, fee2, c = sys.argv[1:6]
def addr(x):
    return x[2:].lower() if x.startswith("0x") else x.lower()
def fee(x):
    return int(x).to_bytes(3, "big").hex()
print("0x" + addr(a) + fee(fee1) + addr(b) + fee(fee2) + addr(c))
PY
}

POOL_STABLE=$(sol_const POOL_FXSAVE_SCRVUSD)
POOL_USD=$(sol_const POOL_CRVUSD_USDC)
SCRVUSD_VAULT=$(sol_const SCRVUSD_VAULT)
USDC=$(sol_const USDC)
WETH=$(sol_const WETH)
WSTETH=$(sol_const WSTETH)
I_FXSAVE=$(sol_const POOL2_I_FXSAVE)
J_SCRVUSD=$(sol_const POOL2_J_SCRVUSD)
I_USDC=$(sol_const POOL_USD_I_USDC)
J_CRVUSD=$(sol_const POOL_USD_J_CRVUSD)
FEE_USDC_WETH=$(sol_const UNI_USDC_WETH_FEE)
FEE_WETH_WSTETH=$(sol_const UNI_WETH_WSTETH_FEE)
PATH_FWD=$(uni_path "${USDC}" "${FEE_USDC_WETH}" "${WETH}" "${FEE_WETH_WSTETH}" "${WSTETH}")
PATH_REV=$(uni_path "${WSTETH}" "${FEE_WETH_WSTETH}" "${WETH}" "${FEE_USDC_WETH}" "${USDC}")
readonly POOL_STABLE POOL_USD SCRVUSD_VAULT USDC WETH WSTETH I_FXSAVE J_SCRVUSD I_USDC J_CRVUSD PATH_FWD PATH_REV

BLOCK=${1:-}
if [[ -z ${BLOCK} ]]; then
  BLOCK=$(cast block-number --rpc-url "${RPC}")
  if [[ -z ${BLOCK} ]]; then
    echo "could not read the chain head — is MAINNET_RPC_URL set?" >&2
    exit 1
  fi
fi
readonly BLOCK

call_at() {
  local block=$1
  shift
  cast call "$@" --block "${block}" --rpc-url "${RPC}" 2>/dev/null | awk '{print $1}'
}

call() {
  call_at "${BLOCK}" "$@"
}

# fxSAVE -> scrvUSD shares -> crvUSD -> USDC -> Uni -> wstETH
forward() {
  local shares crvusd usdc out
  shares=$(call "${POOL_STABLE}" "get_dy(int128,int128,uint256)(uint256)" "${I_FXSAVE}" "${J_SCRVUSD}" "$1")
  [[ -z ${shares} ]] && { echo 0; return; }
  crvusd=$(call "${SCRVUSD_VAULT}" "previewRedeem(uint256)(uint256)" "${shares}")
  [[ -z ${crvusd} ]] && { echo 0; return; }
  usdc=$(call "${POOL_USD}" "get_dy(int128,int128,uint256)(uint256)" "${J_CRVUSD}" "${I_USDC}" "${crvusd}")
  [[ -z ${usdc} ]] && { echo 0; return; }
  out=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_FWD}" "${usdc}")
  echo "${out:-0}"
}

# wstETH -> Uni -> USDC -> crvUSD -> scrvUSD shares -> fxSAVE
reverse() {
  local usdc crvusd shares out
  usdc=$(call "${QUOTER_V1}" "quoteExactInput(bytes,uint256)(uint256)" "${PATH_REV}" "$1")
  [[ -z ${usdc} || ${usdc} == 0 ]] && { echo 0; return; }
  crvusd=$(call "${POOL_USD}" "get_dy(int128,int128,uint256)(uint256)" "${I_USDC}" "${J_CRVUSD}" "${usdc}")
  [[ -z ${crvusd} ]] && { echo 0; return; }
  shares=$(call "${SCRVUSD_VAULT}" "previewDeposit(uint256)(uint256)" "${crvusd}")
  [[ -z ${shares} ]] && { echo 0; return; }
  out=$(call "${POOL_STABLE}" "get_dy(int128,int128,uint256)(uint256)" "${J_SCRVUSD}" "${I_FXSAVE}" "${shares}")
  echo "${out:-0}"
}

echo "=== fxSAVE <-> wstETH route cost (ETH), measured at block ${BLOCK} ==="
echo "    fxSAVE/scrvUSD  ${POOL_STABLE}"
echo "    crvUSD/USDC     ${POOL_USD}"
echo "    Uni path fwd    ${PATH_FWD}"
echo "    scrvUSD vault   ${SCRVUSD_VAULT}"

FEE_STABLE=$(call "${POOL_STABLE}" "fee()(uint256)")
FEE_USD=$(call "${POOL_USD}" "fee()(uint256)")
BALANCE_FXSAVE=$(call "${POOL_STABLE}" "balances(uint256)(uint256)" "${I_FXSAVE}")
BALANCE_SCRVUSD=$(call "${POOL_STABLE}" "balances(uint256)(uint256)" "${J_SCRVUSD}")
if [[ -z ${FEE_STABLE} || -z ${FEE_USD} || -z ${BALANCE_FXSAVE} || -z ${BALANCE_SCRVUSD} ]]; then
  echo "a Curve pool did not answer at block ${BLOCK}" >&2
  exit 1
fi
readonly FEE_STABLE FEE_USD BALANCE_FXSAVE BALANCE_SCRVUSD

echo
echo "=== Section 1: fxSAVE/scrvUSD fee + depth -> FXSAVE_SCRVUSD_POOL_FEE ==="
python3 - "${FEE_STABLE}" "${BALANCE_FXSAVE}" "${BALANCE_SCRVUSD}" "${SHALLOW_SIDE_PERCENT}" <<'PY'
import sys
fee, fxsave, scrvusd, percent = (int(x) for x in sys.argv[1:5])
print(f"fxSAVE/scrvUSD fee   {fee / 1e8:.4f}%   ({fee * 10**8:.3e} as a 1e18-scaled ratio)")
print(f"pool balances        {fxsave / 1e18:,.0f} fxSAVE against {scrvusd / 1e18:,.0f} scrvUSD")
print(f"sizing basis         {percent}% of the fxSAVE side = {fxsave * percent // 100 / 1e18:,.0f} fxSAVE")
PY

echo
echo "=== Section 2: static mid-leg fees -> CRVUSD_USDC_POOL_FEE + UNI fees ==="
python3 - "${FEE_USD}" "${FEE_USDC_WETH}" "${FEE_WETH_WSTETH}" <<'PY'
import sys
fee_usd, fee_uw, fee_ww = (int(x) for x in sys.argv[1:4])
print(f"crvUSD/USDC fee      {fee_usd / 1e8:.4f}%   ({fee_usd * 10**8:.3e})")
print(f"Uni USDC/WETH        {fee_uw / 1e4:.4f}%   ({fee_uw / 1e6 * 1e18:.3e})  (tier {fee_uw})")
print(f"Uni WETH/wstETH      {fee_ww / 1e4:.4f}%   ({fee_ww / 1e6 * 1e18:.3e})  (tier {fee_ww})")
# Uni fee tiers are hundredths of a bip (100 = 0.01%); express as 1e18 ratio:
# percent = fee / 1e6 * 100; ratio = percent/100 * 1e18 = fee / 1e6 * 1e18
PY

impact_at() {
  local direction=$1 epsilon_out=$2 size=$3 out
  out=$("${direction}" "${size}")
  python3 - "${EPSILON}" "${epsilon_out}" "${size}" "${out:-0}" "${FEE_STABLE}" <<'PY'
import sys
epsilon, epsilon_out, size, out, fee_stable = (int(x) for x in sys.argv[1:6])
if out == 0 or epsilon_out == 0:
    print(f"{size / 1e18:>16,.3f} {'reverted/zero':>18} {'-':>11} {'-':>11}\t0")
else:
    impact = 1 - (out / size) / (epsilon_out / epsilon)
    with_static = 1 - (1 - impact) * (1 - fee_stable / 1e10)
    print(f"{size / 1e18:>16,.3f} {out / 1e18:>18,.4f} {impact * 100:>10.4f}% "
          f"{with_static * 100:>10.4f}%\t{impact * 100:.6f}")
PY
}

BASIS_FXSAVE=$(big "${BALANCE_FXSAVE} * ${SHALLOW_SIDE_PERCENT} // 100")
BASIS_WSTETH=$(forward "${BASIS_FXSAVE}")
EPSILON_OUT_FORWARD=$(forward "${EPSILON}")
EPSILON_OUT_REVERSE=$(reverse "${EPSILON}")
readonly BASIS_FXSAVE BASIS_WSTETH EPSILON_OUT_FORWARD EPSILON_OUT_REVERSE

if [[ ${BASIS_WSTETH} == 0 || ${EPSILON_OUT_FORWARD} == 0 || ${EPSILON_OUT_REVERSE} == 0 ]]; then
  echo "the route did not quote at block ${BLOCK} — Section 3 cannot measure impact" >&2
  exit 1
fi

echo
echo "=== Section 3: price impact -> the two EXPECTED_SLIPPAGE terms ==="
echo "measured against each direction's own quote at ${EPSILON} wei"

readonly SIZE_PERCENTS=(25 50 100 200 1000)
BASIS_FXSAVE_LABEL=$(big "f'{${BASIS_FXSAVE} / 1e18:,.0f}'")
BASIS_WSTETH_LABEL=$(big "f'{${BASIS_WSTETH} / 1e18:,.3f}'")

echo
echo "--- FORWARD fxSAVE -> wstETH (basis ${BASIS_FXSAVE_LABEL} fxSAVE) ---"
printf "%16s %18s %11s %11s\n" "size (fxSAVE)" "out (wstETH)" "impact" "+ static"
for percent in "${SIZE_PERCENTS[@]}"; do
  row=$(impact_at forward "${EPSILON_OUT_FORWARD}" "$(big "${BASIS_FXSAVE} * ${percent} // 100")")
  printf '%s\n' "${row%%$'\t'*}"
  if [[ ${percent} -eq 100 ]]; then
    IMPACT_FORWARD=${row##*$'\t'}
  fi
done

echo
echo "--- REVERSE wstETH -> fxSAVE (basis ${BASIS_WSTETH_LABEL} wstETH) ---"
printf "%16s %18s %11s %11s\n" "size (wstETH)" "out (fxSAVE)" "impact" "+ static"
for percent in "${SIZE_PERCENTS[@]}"; do
  row=$(impact_at reverse "${EPSILON_OUT_REVERSE}" "$(big "${BASIS_WSTETH} * ${percent} // 100")")
  printf '%s\n' "${row%%$'\t'*}"
  if [[ ${percent} -eq 100 ]]; then
    IMPACT_REVERSE=${row##*$'\t'}
  fi
done
readonly IMPACT_FORWARD IMPACT_REVERSE

echo
echo "=== Section 4: composed constants -> script/src/config/ConfigSwap_ETH_mainnet.sol ==="
python3 - "${FEE_STABLE}" "${FEE_USD}" "${FEE_USDC_WETH}" "${FEE_WETH_WSTETH}" \
  "${IMPACT_FORWARD}" "${IMPACT_REVERSE}" <<'PY'
import sys

fee_stable = int(sys.argv[1]) / 1e8
fee_usd = int(sys.argv[2]) / 1e8
# Uni tiers: 100 = 0.01%, 500 = 0.05%  → percent = tier / 1e4
uni_uw = int(sys.argv[3]) / 1e4
uni_ww = int(sys.argv[4]) / 1e4
impact_forward, impact_reverse = (float(x) for x in sys.argv[5:7])


def scaled(percent):
    return percent / 100 * 1e18


print(f"FXSAVE_SCRVUSD_POOL_FEE            {scaled(fee_stable):>10.3e}   {fee_stable:.4f}%")
print(f"CRVUSD_USDC_POOL_FEE               {scaled(fee_usd):>10.3e}   {fee_usd:.4f}%")
print(f"UNI_USDC_WETH_FEE                  {scaled(uni_uw):>10.3e}   {uni_uw:.4f}%")
print(f"UNI_WETH_WSTETH_FEE                {scaled(uni_ww):>10.3e}   {uni_ww:.4f}%")
print(f"FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE {scaled(impact_forward):>10.3e}   {impact_forward:.4f}%")
print(f"WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE {scaled(impact_reverse):>10.3e}   {impact_reverse:.4f}%")
print()
fwd = fee_stable + fee_usd + uni_uw + uni_ww + impact_forward
rev = fee_stable + fee_usd + uni_uw + uni_ww + impact_reverse
print(f"FXSAVE_TO_WSTETH_ROUTE_COST_RATIO  {scaled(fwd):>10.3e}   {fwd:.4f}%")
print(f"WSTETH_TO_FXSAVE_ROUTE_COST_RATIO  {scaled(rev):>10.3e}   {rev:.4f}%")
print()
print("Round before writing — pool fees move more than the last digit.")
PY
