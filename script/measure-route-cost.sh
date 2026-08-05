#!/usr/bin/env bash
#
# Re-derives the fxSAVE <-> wstETH `routeCostRatio` constants from live mainnet state.
#
# WHAT IT IS FOR
# --------------
# `script/src/config/ConfigSwap_ETH_mainnet.sol` stores one expected-cost number per direction in
# the swap registry: the venue fees plus the price impact expected at a typical trade size. Those
# numbers were measured, not guessed, and this script is the measurement — so they can be
# re-derived when the pools move rather than re-discovered from scratch.
#
# It prints the terms the constants are composed from, in the order the config states them, then
# the composed values ready to compare against what is configured:
#
#   Section 1  static fxSAVE/scrvUSD pool fee      -> FXSAVE_SCRVUSD_POOL_FEE
#   Section 2  TricryptoLLAMA dynamic-fee sample   -> TRICRYPTO_LLAMA_EXPECTED_FEE
#   Section 3  price impact vs trade size          -> FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE
#                                                     WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE
#   Section 4  the two composed ratios
#
# WHY EACH SECTION EXISTS
# -----------------------
# - The TricryptoLLAMA fee is recomputed from pool balances on every trade, so a single reading
#   says nothing about what the route costs on average: readings taken minutes apart have differed
#   by seven times. Section 2 samples the distribution over a quarter and reports the mean, because
#   this number feeds merit-order RANKING, which wants an unbiased estimate rather than a safe
#   bound. (The revert floor is a separate, oracle-derived number, so being wrong here mis-ranks a
#   route; it does not lose funds.)
# - Price impact is measured against the route's OWN quote at a negligible size, where impact
#   vanishes — so that quote is "spot after fees" and everything below it is impact alone.
# - The size impact is quoted at is derived here, not hardcoded: 5% of the shallow side of the
#   fxSAVE/scrvUSD pool. That pool is fxSAVE-light, so the directions are asymmetric — adding
#   fxSAVE moves it toward balance and is cheap, taking fxSAVE out moves it away and costs several
#   times more for the same value. Section 3 prints both, and sizes either side of the basis so the
#   choice of basis can be re-judged rather than inherited.
#
# HOW TO RUN
# ----------
#   MAINNET_RPC_URL=https://... yarn measure:route-cost              # at the chain head
#   MAINNET_RPC_URL=https://... yarn measure:route-cost 25682862     # at a pinned block
#
# Run from the repository root: `cast` resolves the `mainnet` endpoint from `foundry.toml`, which
# reads `MAINNET_RPC_URL`. Needs `cast` (foundry) and `python3`. Pass a block number to reproduce a
# past measurement exactly — the values currently in the config were taken at block 25,682,862.
# Section 2 reads historical blocks, so the endpoint must be an archive node. Roughly 80 calls, a
# couple of minutes; every one is a read.
#
# The route's addresses and coin indices are read out of the Solidity route config rather than
# repeated here, so a route change moves this script with it.
#
set -o pipefail

readonly RPC="mainnet"
readonly ROUTE_CONFIG="src/swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol"
readonly FEE_SAMPLES=30
readonly FEE_SPAN_BLOCKS=648000 # ~90 days at 12s blocks
readonly SHALLOW_SIDE_PERCENT=5 # the sizing basis: percent of the pool's fxSAVE side traded
readonly EPSILON=1000000000000000 # 0.001 token — small enough that impact is below a basis point

if [[ ! -f ${ROUTE_CONFIG} ]]; then
  echo "run from the repository root: ${ROUTE_CONFIG} not found" >&2
  exit 1
fi

# Token amounts run past 1e22, so every amount calculation goes through python — bash arithmetic is
# 64-bit and would silently wrap.
big() {
  python3 -c "print($1)"
}

# Read a constant's value out of the Solidity route config, so this script never holds a second
# copy of an address or a coin index.
sol_const() {
  local name=$1 value
  value=$(grep -oP "constant\s+${name}\s*=\s*\K[^;]+" "${ROUTE_CONFIG}" | tr -d ' ')
  if [[ -z ${value} ]]; then
    echo "constant ${name} not found in ${ROUTE_CONFIG}" >&2
    exit 1
  fi
  echo "${value}"
}

POOL_STABLE=$(sol_const POOL_FXSAVE_SCRVUSD)
POOL_CRYPTO=$(sol_const POOL_TRICRYPTO_LLAMA)
SCRVUSD_VAULT=$(sol_const SCRVUSD_VAULT)
I_FXSAVE=$(sol_const POOL2_I_FXSAVE)
J_SCRVUSD=$(sol_const POOL2_J_SCRVUSD)
I_CRVUSD=$(sol_const POOL1_I_CRVUSD)
J_WSTETH=$(sol_const POOL1_J_WSTETH)
readonly POOL_STABLE POOL_CRYPTO SCRVUSD_VAULT I_FXSAVE J_SCRVUSD I_CRVUSD J_WSTETH

BLOCK=${1:-}
if [[ -z ${BLOCK} ]]; then
  BLOCK=$(cast block-number --rpc-url "${RPC}")
  if [[ -z ${BLOCK} ]]; then
    echo "could not read the chain head — is MAINNET_RPC_URL set?" >&2
    exit 1
  fi
fi
readonly BLOCK

# Every read is pinned to one block so the sections compose. `cast` annotates integers with a
# scientific-notation suffix ("1234 [1.2e3]"); the first field is the plain integer.
call_at() {
  local block=$1
  shift
  cast call "$@" --block "${block}" --rpc-url "${RPC}" 2>/dev/null | awk '{print $1}'
}

call() {
  call_at "${BLOCK}" "$@"
}

# fxSAVE -> scrvUSD shares -> crvUSD -> wstETH. Echoes 0 if any leg fails to quote.
forward() {
  local shares crvusd out
  shares=$(call "${POOL_STABLE}" "get_dy(int128,int128,uint256)(uint256)" "${I_FXSAVE}" "${J_SCRVUSD}" "$1")
  if [[ -z ${shares} ]]; then
    echo 0
    return
  fi
  crvusd=$(call "${SCRVUSD_VAULT}" "previewRedeem(uint256)(uint256)" "${shares}")
  if [[ -z ${crvusd} ]]; then
    echo 0
    return
  fi
  out=$(call "${POOL_CRYPTO}" "get_dy(uint256,uint256,uint256)(uint256)" "${I_CRVUSD}" "${J_WSTETH}" "${crvusd}")
  echo "${out:-0}"
}

# wstETH -> crvUSD -> scrvUSD shares -> fxSAVE. Echoes 0 if any leg fails to quote.
reverse() {
  local crvusd shares out
  crvusd=$(call "${POOL_CRYPTO}" "get_dy(uint256,uint256,uint256)(uint256)" "${J_WSTETH}" "${I_CRVUSD}" "$1")
  if [[ -z ${crvusd} ]]; then
    echo 0
    return
  fi
  shares=$(call "${SCRVUSD_VAULT}" "previewDeposit(uint256)(uint256)" "${crvusd}")
  if [[ -z ${shares} ]]; then
    echo 0
    return
  fi
  out=$(call "${POOL_STABLE}" "get_dy(int128,int128,uint256)(uint256)" "${J_SCRVUSD}" "${I_FXSAVE}" "${shares}")
  echo "${out:-0}"
}

echo "=== fxSAVE <-> wstETH route cost, measured at block ${BLOCK} ==="
echo "    fxSAVE/scrvUSD  ${POOL_STABLE}  (StableSwap-NG, static fee)"
echo "    TricryptoLLAMA  ${POOL_CRYPTO}  (crypto pool, dynamic fee)"
echo "    scrvUSD vault   ${SCRVUSD_VAULT}  (ERC4626, no fee)"

# ------------------------------------------------------------------------------------------------
# Section 1 — the static leg fee, and the depth the sizing basis is taken from.
# ------------------------------------------------------------------------------------------------
FEE_STABLE=$(call "${POOL_STABLE}" "fee()(uint256)")
BALANCE_FXSAVE=$(call "${POOL_STABLE}" "balances(uint256)(uint256)" "${I_FXSAVE}")
BALANCE_SCRVUSD=$(call "${POOL_STABLE}" "balances(uint256)(uint256)" "${J_SCRVUSD}")
if [[ -z ${FEE_STABLE} || -z ${BALANCE_FXSAVE} || -z ${BALANCE_SCRVUSD} ]]; then
  echo "the fxSAVE/scrvUSD pool did not answer at block ${BLOCK}" >&2
  exit 1
fi
readonly FEE_STABLE BALANCE_FXSAVE BALANCE_SCRVUSD

echo
echo "=== Section 1: static fee and depth -> FXSAVE_SCRVUSD_POOL_FEE ==="
python3 - "${FEE_STABLE}" "${BALANCE_FXSAVE}" "${BALANCE_SCRVUSD}" "${SHALLOW_SIDE_PERCENT}" <<'PY'
import sys

fee, fxsave, scrvusd, percent = (int(x) for x in sys.argv[1:5])
# Curve scales fees by 1e10; the config stores ratios 1e18-scaled.
print(f"fxSAVE/scrvUSD fee   {fee / 1e8:.4f}%   ({fee * 10**8:.3e} as a 1e18-scaled ratio)")
print(f"pool balances        {fxsave / 1e18:,.0f} fxSAVE against {scrvusd / 1e18:,.0f} scrvUSD")
print(f"sizing basis         {percent}% of the fxSAVE side = {fxsave * percent // 100 / 1e18:,.0f} fxSAVE")
PY

# ------------------------------------------------------------------------------------------------
# Section 2 — the dynamic leg fee, as a distribution rather than a reading.
# ------------------------------------------------------------------------------------------------
readonly STEP=$((FEE_SPAN_BLOCKS / FEE_SAMPLES))
readonly STEP_HOURS=$((STEP * 12 / 3600))

echo
echo "=== Section 2: TricryptoLLAMA dynamic fee -> TRICRYPTO_LLAMA_EXPECTED_FEE ==="
echo "${FEE_SAMPLES} samples every ${STEP} blocks (~${STEP_HOURS}h) back over ~90 days"

FEE_SERIES=""
for ((k = FEE_SAMPLES - 1; k >= 0; k--)); do
  sample_block=$((BLOCK - k * STEP))
  sample_fee=$(call_at "${sample_block}" "${POOL_CRYPTO}" "fee()(uint256)")
  if [[ -n ${sample_fee} ]]; then
    FEE_SERIES+="${sample_block} ${sample_fee}"$'\n'
  fi
done
readonly FEE_SERIES

if [[ -z ${FEE_SERIES} ]]; then
  echo "no fee samples returned — Section 2 needs an archive node for historical blocks" >&2
  exit 1
fi

# The distribution, then its mean alone on the last line for Section 4 to compose with.
FEE_REPORT=$(printf '%s' "${FEE_SERIES}" | python3 -c '
import statistics
import sys

rows = [line.split() for line in sys.stdin if line.strip()]
fees = [int(fee) / 1e8 for _, fee in rows]  # 1e10-scaled -> percent
for (block, _), percent in zip(rows, fees):
    print(f"{block:>10}  {percent:>8.4f}%  {chr(35) * max(1, round(percent * 20))}")
quartiles = statistics.quantiles(fees, n=4)
print(f"samples {len(fees)}   min {min(fees):.4f}%   p25 {quartiles[0]:.4f}%   "
      f"median {statistics.median(fees):.4f}%   mean {statistics.mean(fees):.4f}%   "
      f"p75 {quartiles[2]:.4f}%   max {max(fees):.4f}%")
print(f"{statistics.mean(fees):.6f}")
')
if [[ ${PIPESTATUS[0]} -ne 0 || -z ${FEE_REPORT} ]]; then
  echo "the fee distribution could not be summarised" >&2
  exit 1
fi
printf '%s\n' "${FEE_REPORT}" | head -n -1
MEAN_FEE_PERCENT=$(printf '%s\n' "${FEE_REPORT}" | tail -n 1)
readonly MEAN_FEE_PERCENT

# ------------------------------------------------------------------------------------------------
# Section 3 — price impact against the route's own marginal rate, both directions.
# ------------------------------------------------------------------------------------------------

# One row of the impact table. Echoes the formatted row and the impact percentage, tab-separated,
# so the caller can both print it and keep the number.
impact_at() {
  local direction=$1 epsilon_out=$2 size=$3 out
  out=$("${direction}" "${size}")
  python3 - "${EPSILON}" "${epsilon_out}" "${size}" "${out:-0}" "${FEE_STABLE}" <<'PY'
import sys

epsilon, epsilon_out, size, out, fee_stable = (int(x) for x in sys.argv[1:6])
if out == 0 or epsilon_out == 0:
    print(f"{size / 1e18:>16,.3f} {'reverted/zero':>18} {'-':>11} {'-':>11}\t0")
else:
    # The epsilon quote already carries both pools' fees, so what is left over it is impact alone.
    impact = 1 - (out / size) / (epsilon_out / epsilon)
    with_static = 1 - (1 - impact) * (1 - fee_stable / 1e10)
    print(f"{size / 1e18:>16,.3f} {out / 1e18:>18,.4f} {impact * 100:>10.4f}% "
          f"{with_static * 100:>10.4f}%\t{impact * 100:.6f}")
PY
}

# The basis size in each direction: 5% of the pool's fxSAVE side, and the wstETH that buys it.
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
echo "measured against each direction's own quote at ${EPSILON} wei, where impact vanishes"
echo "the 100% row is the basis size and the one the config quotes; the others show the curve"

# Percentages of the basis size: either side of it, then far past it to show where depth gives out.
readonly SIZE_PERCENTS=(25 50 100 200 1000)

BASIS_FXSAVE_LABEL=$(big "f'{${BASIS_FXSAVE} / 1e18:,.0f}'")
BASIS_WSTETH_LABEL=$(big "f'{${BASIS_WSTETH} / 1e18:,.3f}'")
readonly BASIS_FXSAVE_LABEL BASIS_WSTETH_LABEL

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

# ------------------------------------------------------------------------------------------------
# Section 4 — the composed constants, in the config's own form.
# ------------------------------------------------------------------------------------------------
echo
echo "=== Section 4: composed constants -> script/src/config/ConfigSwap_ETH_mainnet.sol ==="
python3 - "${FEE_STABLE}" "${MEAN_FEE_PERCENT}" "${IMPACT_FORWARD}" "${IMPACT_REVERSE}" <<'PY'
import sys

fee_stable_percent = int(sys.argv[1]) / 1e8
mean_crypto_fee_percent, impact_forward, impact_reverse = (float(x) for x in sys.argv[2:5])


def scaled(percent):
    """A percentage as the 1e18-scaled ratio the config stores."""
    return percent / 100 * 1e18


print(f"FXSAVE_SCRVUSD_POOL_FEE            {scaled(fee_stable_percent):>10.3e}   {fee_stable_percent:.4f}%")
print(f"TRICRYPTO_LLAMA_EXPECTED_FEE       {scaled(mean_crypto_fee_percent):>10.3e}   "
      f"{mean_crypto_fee_percent:.4f}%  (the mean above)")
print(f"FXSAVE_TO_WSTETH_EXPECTED_SLIPPAGE {scaled(impact_forward):>10.3e}   {impact_forward:.4f}%")
print(f"WSTETH_TO_FXSAVE_EXPECTED_SLIPPAGE {scaled(impact_reverse):>10.3e}   {impact_reverse:.4f}%")
print()
forward_total = fee_stable_percent + mean_crypto_fee_percent + impact_forward
reverse_total = fee_stable_percent + mean_crypto_fee_percent + impact_reverse
print(f"FXSAVE_TO_WSTETH_ROUTE_COST_RATIO  {scaled(forward_total):>10.3e}   {forward_total:.4f}%")
print(f"WSTETH_TO_FXSAVE_ROUTE_COST_RATIO  {scaled(reverse_total):>10.3e}   {reverse_total:.4f}%")
print()
print("The terms are summed, as the config sums them: they compound multiplicatively, but below 1%")
print("the difference is under a basis point. Round before writing them in — the dynamic fee moves")
print("far more than the last digit does.")
PY
