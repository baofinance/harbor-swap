# Swap executor — divergence from the original design

**Status:** IMPLEMENTED on branch `swap-executor-hardening` (PR #2) and carried into
`velora-swap`. Every change below is built and verified on the hardening branch: unit +
pinned mainnet fork tests (block 25,500,000 — both FxSave composite directions execute within
0.1% of on-chain quotes, and the no-allowance `redeem` is proven against the real scrvUSD
vault). The unit suite includes a permanent mock-form regression pin of the §1 defect
(a StableSwap-declared route against a crypto pool reverts `ZeroAmountOut` instead of
silently consuming funds), "liar venue" tests proving the envelope's floor is the guard that
actually protects callers, mixed-decimals fixtures on the generic executors (6↔18), and full
UUPS upgrade/initialise-surface coverage.

**Update:** `UniV3Swapper_v1` and `BalancerSwapper_v1` **are** converted onto
`SwapExecutorBase` (commit `a38d1ab`). All five original executors share the envelope.
`VeloraSwapper_v1` (this branch) adopts the same base.

**Audience:** the original author of `OneInchSwapper_v1`, `CurveSwapper_v1`,
`FxSaveWstEthSwapper_v1` and their configs. This document states, for each change, what the
**original design was**, what **evidence** prompted the change, **what changes**, and **how
to push back**. Nothing here is a criticism of intent — most of the original design is kept.
The one item that is a genuine defect (§1) was invisible to the existing tests by
construction, which is itself the most important finding.

Where a change is a *judgement call* rather than a defect, it is marked **[judgement]** and
the counter-argument is given explicitly, so it can be rejected without re-deriving it.

---

## Summary

| # | Change | Kind |
|---|---|---|
| 1 | `FxSaveWstEthSwapper_v1` calls the wrong Curve `exchange` selector on TricryptoLLAMA — the route cannot work on mainnet | **defect** |
| 2 | Curve pool *family* (StableSwap `int128` vs crypto `uint256`) becomes route data; shared `CurveExchangeLib` | consequence of §1 |
| 3 | New `SwapExecutorBase` abstract owning the invariants common to all executors | **[judgement]** |
| 4 | Same-token calls revert instead of passing through | **[judgement]** |
| 5 | Exact-pull check (fee-on-transfer detected up front, not via an underflow) | hardening |
| 6 | Error taxonomy: `Token.ZeroInputBalance` for zero intermediates; vault errors only when the vault is the actor | hardening |
| 7 | Delete the dead `forceApprove` around the ERC-4626 `redeem` | cleanup |
| 8 | Intermediate amounts measured as a **delta**, not a full `balanceOf` (already merged) | hardening |
| 9 | `TokenHolder` adopted → owner-gated `sweep` (already merged) | hardening |
| 10 | Mocks rewritten to model the *real* dependencies, not the code's assumptions | **test defect** |
| 11 | Fork tests introduced (pinned block) — the repo had none | **test gap** |
| 12 | 1inch router calldata is **NOT** decoded/validated beyond the selector | **decision: no change** |

---

## 1. DEFECT — `FxSaveWstEthSwapper_v1` cannot execute on mainnet

### Original design

`_curveExchange` encodes one signature for every pool it talks to:

```solidity
bytes memory callData = abi.encodeWithSignature(
    "exchange(int128,int128,uint256,uint256)", i, j, amountIn, minDy
);
(bool ok, bytes memory revertData) = pool.call(callData);
```

and `ConfigFxSaveWstEthRoute_ETH_mainnet` declares all four indices as `int128`. The config's
docstring says *"Pool coin indices verified on-chain via `coins(uint256)` at deployment time."*

### Evidence (verified against Ethereum mainnet)

Curve maintains **two pool families with different index types**. The route crosses both:

| Pool | Family | `exchange(int128,int128,uint256,uint256)` `0x3df02124` | `exchange(uint256,uint256,uint256,uint256)` `0x5b41b908` |
|---|---|---|---|
| fxSAVE/scrvUSD `0xb6E4…48E2` | StableSwap-NG | **present** | absent |
| TricryptoLLAMA `0x2889…3D13` | crypto | **ABSENT** | **present** |

TricryptoLLAMA does not implement the `int128` selector at all.

**And it does not revert when called with it.** TricryptoLLAMA is a Curve crypto pool with a
Vyper `__default__` function (crypto pools have one to receive ETH), so **any unknown selector
hits the fallback and returns SUCCESS with empty data**:

| staticcall to TricryptoLLAMA | result |
|---|---|
| garbage selector `0xdeadbeef` | **`0x` — SUCCESS, empty return** |
| `exchange(int128,…)` `0x3df02124` — *what the code sends* | **`0x` — SUCCESS, empty return** |
| `exchange(uint256,…)` `0x5b41b908` — the correct one | `execution reverted` (it *dispatched* to the real, state-changing function) |

So `_curveExchange` receives `ok == true`, finds no revert, and **carries on as though the
swap happened. It did not.** The leg is a silent no-op.

### Failure mode — asymmetric, and one side loses funds

TricryptoLLAMA is on **both** routes (forward leg 3, crvUSD → wstETH; reverse leg 1,
wstETH → crvUSD), but the two directions fail very differently:

**Reverse (`wstETH → fxSAVE`)** — leg 1 no-ops → `crvUsdBal == 0` → reverts
`VaultDepositFailed`. No funds lost. But the error blames the **vault** for a **Curve leg**
failure — see §6. That misleading error has been masking this bug.

**Reverse is safe. Forward is not.**

**Forward (`fxSAVE → wstETH`)**:
1. leg 1 (fxSAVE/scrvUSD, StableSwap `int128`) — **works**, produces scrvUSD shares
2. `redeem` — works, produces crvUSD
3. leg 3 (TricryptoLLAMA) — **silently does nothing**
4. `amountOut = wstETH delta = 0`
5. `if (amountOut < minAmountOut) revert InsufficientOutput(...)` — **only fires if
   `minAmountOut > 0`**

With **`minAmountOut == 0` there is no revert**: the function emits its event, transfers 0
wstETH, and **returns 0 — while the caller's fxSAVE has already been consumed and now sits in
the adapter as stranded crvUSD.** That is **silent fund loss**, not an unusable route.

(It is recoverable only via the `sweep` added in §9 — which was luck, not design.)

This matters because a zero `minAmountOut` is not hypothetical: the consumer's
`SwapLib_v1.swapFloor` **fails open to `0`** when a valuation rate reads zero (see the closing
section), and `redistribute`'s unwind rungs pass `0` by design.

### Consequence: `InsufficientOutput` is load-bearing, not redundant

An earlier reading of this code held that the executor's own `amountOut >= minAmountOut` check
was dead — shadowed by the pool's own `min_dy` enforcement, which reverts first. **That is
only true when the pool actually executes.** When the call no-ops, the pool never sees `min_dy`
at all, and the executor's own check is the *sole* thing between this bug and silent loss. It
must stay, and §3 strengthens it.

Everything *else* about the route is correct — the addresses and indices check out on-chain:

```
TricryptoLLAMA   coins(0)=crvUSD  coins(1)=tBTC  coins(2)=wstETH   (config: I_CRVUSD=0, J_WSTETH=2)  ✓
fxSAVE/scrvUSD   coins(0)=fxSAVE  coins(1)=scrvUSD                 (config: I_FXSAVE=0, J_SCRVUSD=1) ✓
liquidity        1.31M crvUSD / 581 wstETH
get_dy(0,2, 1000 crvUSD) = 0.4470 wstETH   → wstETH ≈ $2,237, economically sane
```

So the venue choice, the pair, the pool addresses and the indices were **all correct**; the
indices *were* verified on-chain exactly as the docstring claims. What was never verified was
the **`exchange` signature**. TricryptoLLAMA remains the right pool and Curve `exchange`
remains the right method — only the encoding is wrong.

### Why no test caught it

`MockCurvePool` implements `exchange(int128,int128,uint256,uint256)` — *precisely the
signature the code calls*. The mock was written from the code's assumption rather than from
the dependency's real ABI, so it could only ever confirm that assumption. Combined with the
fact that the repo has **no fork tests at all** (no `createSelectFork` anywhere under
`test/`), nothing ever touched real pool bytecode. See §10 and §11.

### Change — three layers, because the failure is *silent*

1. **Encode per pool family.** Route data carries the family; `CurveExchangeLib` (§2) does the
   encoding. This removes *this* instance.
2. **`amountOut == 0` is always fatal**, independent of `minAmountOut` (in `SwapExecutorBase`,
   §3). A swap that produced nothing is a failed swap, full stop. This kills the *class*: any
   venue with a permissive fallback can accept a call and do nothing, and we must not depend on
   the caller having passed a non-zero floor — we have *proven* callers sometimes pass zero.
3. **Config-time family conformance check** (fork test, §11) so a route can never again be
   configured against a pool that does not implement the selector it will be called with.

Defence in depth is warranted precisely *because* the failure is silent rather than loud.

### How to challenge

The evidence is reproducible with three `cast` calls against the two pool addresses: the
selector-presence check, the `__default__`-returns-success check, and a live `get_dy` quote. If
you believe TricryptoLLAMA should not be the venue at all, that is a separate (and reasonable)
discussion — but the pool holds the pair with real liquidity and quotes sanely, so it looks
right. If you think layer 2 (`amountOut == 0` fatal) is over-reach, note that without it the
forward route silently consumed user funds; a zero-output swap has no legitimate meaning.

---

## 2. Curve pool family becomes route data (`CurveExchangeLib`)

### Original design

Both `CurveSwapper_v1` and `FxSaveWstEthSwapper_v1` hardcode the `int128` `exchange`
signature. `CurveSwapper_v1.CurveRoute` carries `{pool, i, j, useUnderlying}` — the `int128`
index type is baked into the struct and the encoder.

### Consequence of §1

Because the `int128` form is hardcoded, `CurveSwapper_v1` **cannot route through any Curve
crypto pool** either. That is not a live bug (routes are governance-set, and none is a crypto
pool today) but it silently excludes half of Curve, and it is the same latent trap that bit
FxSave.

### Change

- `CurveRoute` gains a governance-declared `kind` (`CurveExchangeLib.CurvePoolKind`:
  `StableSwap` | `Crypto`); `setRoute` becomes
  `setRoute(from, to, pool, kind, i, j, useUnderlying)` and additionally rejects negative
  indices.
- A shared `CurveExchangeLib` owns the calldata encoding for both families, used by **both**
  executors — the encoder is not duplicated. Indices stay `int128` at the API (they carry both
  families' 0..8 range) and are cast to `uint256` for crypto pools. `PoolCallFailed(bytes)`
  moves into the lib (its single home; the error selector is unchanged).
- `ConfigFxSaveWstEthRoute_ETH_mainnet` declares `POOL_TRICRYPTO_LLAMA_KIND = Crypto` and
  `POOL_FXSAVE_SCRVUSD_KIND = StableSwap` next to the pool addresses they describe.

The low-level `call` is retained (it is what makes the executor agnostic to Curve's
void-return vs `uint256`-return `exchange`), so the balance-delta accounting stays as-is.

### Why data (an enum) and not a contract split

The alternative — `CurveStableSwapSwapper` + `CurveCryptoSwapper`, with the `Swapper_v1`
registry's executor choice carrying the family — was considered and rejected for two reasons:
1. `FxSaveWstEthSwapper`'s single composite swap crosses **both** families internally (leg 1
   StableSwap, leg 3 crypto). It *is* the contract doing the swap and still needs the
   discriminator inside itself — so the lib + kind must exist anyway; a split would only add a
   second proxy on top of it.
2. The kind must agree with the pool address and indices; storing them in one struct, set in
   one governance action, keeps that consistency atomic. A contract split moves the family
   decision into a different config action (the registry's executor choice), away from the
   data it must match.
The line drawn: **contract per venue, data per ABI-variant within a venue.**

### How to challenge

You could argue for supporting only one family and choosing pools accordingly. That does not
work here: the required route genuinely crosses both families (§1), so the discriminator is
forced. If you prefer the contract-split shape regardless, address the FxSave composite (point
1 above) — it is the case that forces an in-contract discriminator to exist either way.

---

## 3. `SwapExecutorBase` — a shared abstract for the executor invariants **[judgement]**

### Original design

Each executor independently implements the same envelope: pull `fromToken` from `msg.sender`,
snapshot balances, call the venue, measure the output delta, enforce `minAmountOut`, return
proceeds to `msg.sender`, reset approvals. Three copies, and they have drifted — see §4, §5,
and the `InsufficientOutput` inconsistency below.

### Evidence of drift

- **Same-token** handling differs three ways (§4).
- **Fee-on-transfer** is assumed away in three different places, one of which underflows (§5).
- **The `minAmountOut` guard has different status in each.** Curve and FxSave pass
  `minAmountOut` to the pool as `min_dy` *and* re-check the balance delta. 1inch, by contrast,
  **cannot** push the bound to the venue (its `minReturn` lives inside the opaque router
  calldata we deliberately do not decode — §12), so there the delta check is the sole guard.

  This asymmetry is a **fact of the venues, not a defect**. But the delta check is *never
  exercised* in the Curve/FxSave tests, because a working pool enforces `min_dy` and reverts
  first — the existing test even documents this (`test_swap_slippage_reverts`: *"pool rejects
  below min_dy → PoolCallFailed wraps"*). §1 shows why that reasoning is dangerous: when the
  pool call **no-ops** (permissive fallback), the pool never sees `min_dy` at all and the
  executor's own delta check is the **only** guard. It is load-bearing, and it was untested.

### Change

Introduce `SwapExecutorBase` (abstract) owning, once:

1. `fromToken == toToken` → revert `SameToken` (§4)
2. pull exactly `amountIn`; revert if the token delivered less (§5)
3. snapshot `toToken`
4. `_execute(...)` — the **only** venue-specific hook
5. `amountOut` = `toToken` delta; **`amountOut == 0` is always fatal** (§1 — a venue with a
   permissive fallback can accept a call and do nothing; we must not depend on the caller
   having passed a non-zero floor), then enforce `amountOut >= minAmountOut` — **the
   authoritative guard**, in every executor, always
6. refund unspent input (measured against the pre-pull balance; underflow-free by
   construction); deliver `amountOut` to `msg.sender`

The base is deliberately **stateless** — it does NOT bundle Initializable / UUPSUpgradeable /
ownership / TokenHolder (this repo's convention is that every UUPS contract composes those
directly, because each has its own init and access needs). Concretes keep their own
`initialize`, apply `nonReentrant` on their external `swap` (the guard arrives via
`TokenHolder_v2`), and implement only `_execute`.

Two ABI-visible consequences of the conversion:
- `InsufficientAmountOut` moved from `IAggregatorSwapper` to the base (same signature, so the
  selector is unchanged); Curve/FxSave's `InsufficientOutput` is superseded by it.
- `FxSaveWstEthSwap` slimmed from 6 fields to 5: `amountOut` is dropped (the final output is
  the function's return value and the envelope's Transfer log; the event is emitted mid-route
  where only the intermediate is known — threading the final amount back in would need hidden
  cross-call state, which this codebase bans).

Concrete executors implement only `_execute`: Curve's low-level `exchange`, 1inch's router
call, FxSave's multi-leg composite (its legs live inside the hook; the outer envelope is the
base's).

The stated invariant becomes: **the adapter's balance-delta check is the authoritative
slippage guard; pushing `minAmountOut` to the venue is an optional venue-specific
early-revert.** That is consistent across all three and makes the 1inch/Curve asymmetry a
deliberate, documented property rather than an accident.

### How to challenge

The counter-argument is that a base class couples three otherwise-independent adapters, and a
future venue may not fit the envelope (e.g. one that pays out to a third party, or is not
`amountIn`-denominated). If you think that is likely, the alternative is to keep them separate
and instead assert the invariants in a shared *test* base. That gets consistency in tests but
not in code, and does not stop the next executor from drifting again. We judged the envelope
stable enough (all three fit it today, including the multi-leg composite) to be worth the
coupling — but this is a judgement, not a defect, and it is reversible.

---

## 4. Same-token: revert, don't pass through **[judgement]**

### Original design — three different behaviours

| Executor | `fromToken == toToken` |
|---|---|
| `OneInchSwapper_v1` | **passthrough**: transfers in and straight back out, and **skips `_validateRouterData`** entirely (arbitrary `routerData` is accepted on this path) |
| `CurveSwapper_v1` | reverts `NoRouteConfigured` |
| `FxSaveWstEthSwapper_v1` | reverts `UnsupportedPair` |

### Evidence

No consumer ever calls an executor with `fromToken == toToken`:
- `SwapLib_v1.swapViaExecutor` short-circuits `if (fromAsset == toAsset) return amountIn;`
  *before* dispatching to the executor.
- `redistribute` only routes through the aggregator when the named tokens differ, and
  explicitly rejects the mismatched combination (`UnexpectedAggregator` /
  `AggregatorRequired`).

So the passthrough branch is unreachable in production, untested, and it is the one path that
bypasses calldata validation.

### Change

All executors revert `SameToken(address)`. The 1inch passthrough branch is deleted.

### How to challenge

If you intended the executors to be safely callable stand-alone by a third party (where a
same-token no-op is a convenience), passthrough is defensible. We judged it not worth an
unvalidated, unreachable branch — a same-token "swap" is a caller bug and should be loud.

---

## 5. Fee-on-transfer: detect up front, don't underflow

### Original design (`OneInchSwapper_v1`)

```solidity
IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
uint256 fromBalanceBefore = IERC20(fromToken).balanceOf(address(this));  // read AFTER the pull
...
uint256 refundedIn = fromBalanceAfter > (fromBalanceBefore - amountIn)
    ? fromBalanceAfter - (fromBalanceBefore - amountIn) : 0;
```

`fromBalanceBefore` is measured *after* the transfer-in, so it is `preExisting + received`,
and the maths subtracts `amountIn` from it to recover `preExisting`.

### Evidence

If the token takes a fee on transfer, `received < amountIn`, and when
`preExisting < amountIn - received` the expression `fromBalanceBefore - amountIn`
**underflows and reverts**. It therefore fails *closed* (no funds at risk) — but via an
opaque arithmetic panic, on an assumption that is nowhere stated. The variable name is also
actively misleading: it is the balance *after* the pull-in. The same unstated assumption
exists in all three executors.

### Change (in `SwapExecutorBase`)

```solidity
uint256 fromBefore = IERC20(fromToken).balanceOf(address(this));   // genuine pre-existing
IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
uint256 received = IERC20(fromToken).balanceOf(address(this)) - fromBefore;
if (received != amountIn) revert UnexpectedAmountIn(amountIn, received);
...
refundedIn = IERC20(fromToken).balanceOf(address(this)) - fromBefore;   // cannot underflow
```

The refund is underflow-impossible *by construction*: the venue's approval is capped at
`amountIn`, so the balance can never fall below `fromBefore`. Fee-on-transfer tokens are now
rejected with a named error instead of a panic.

### How to challenge

If fee-on-transfer tokens are meant to be *supported* (rather than rejected), this is the
wrong fix and the accounting needs to be rebuilt around `received` throughout. We assumed
they are out of scope — say so explicitly if not.

---

## 6. Error taxonomy — report the observed fact, not a guessed culprit

### Original design (`FxSaveWstEthSwapper_v1`)

`VaultDepositFailed` is raised at **two** distinct sites, and `VaultRedeemFailed` conflates
two causes:

| Site | Condition | Error raised | Actually caused by |
|---|---|---|---|
| reverse | `crvUsdBal == 0` after the **Curve** leg | `VaultDepositFailed` | the Curve leg produced nothing — *not a deposit at all* |
| reverse | `vaultShares == 0` after `deposit(>0)` | `VaultDepositFailed` | the vault — correct |
| forward | `crvUsdOut == 0` after `redeem(shares)` | `VaultRedeemFailed` | the vault **or** leg 1 producing zero shares (forward never checks the leg-1 delta) |

Two different failures raise the same error, and one of them blames a component that was not
involved. That is the "error messages report facts, not assumptions" rule.

### Change

Use the existing bao-base error for the observed fact, and keep the vault errors only where
the vault genuinely is the actor:

- zero **intermediate** after a Curve leg → `Token.ZeroInputBalance(<that token>)`
- vault took `>0` and returned `0` → `VaultDepositFailed` / `VaultRedeemFailed`

Applied symmetrically to both directions (forward gains the missing leg-1 zero check).

### How to challenge

If `VaultDepositFailed` was intended as a generic "the reverse route degenerated" signal, say
so — but then it should be named for that, and the two sites still need to be distinguishable.

---

## 7. Delete the dead `forceApprove` around the ERC-4626 `redeem`

### Original design

```solidity
IERC20(_scrvUsdVault()).forceApprove(_scrvUsdVault(), vaultShares);
uint256 crvUsdOut = IERC4626(_scrvUsdVault()).redeem(vaultShares, address(this), address(this));
IERC20(_scrvUsdVault()).forceApprove(_scrvUsdVault(), 0);
```

### Evidence

The adapter makes the call itself, and passes `address(this)` as the `owner` argument — so
from the vault's perspective `caller == owner`. ERC-4626 only consumes an allowance when they
differ:

```solidity
if (caller != owner) { _spendAllowance(owner, caller, shares); }
```

No allowance is ever spent, so the approve/reset pair is dead code (gas + surface). Note the
target vault (scrvUSD, `0x0655…4367`) is a **45-byte minimal proxy** (Yearn-V3 blueprint), so
this **cannot be confirmed by static bytecode inspection** — it is confirmed by the ERC-4626
spec and by the fork test, which exercises the real vault with the approve removed.

### Change

Delete both approves, and leave a comment stating *why* no allowance is needed (so the
misunderstanding is not reintroduced). The **fork test is the proof** — it redeems from the
real scrvUSD vault with no allowance in place.

### How to challenge

If the approve was there to accommodate a *non-standard* vault, name it — but scrvUSD's
ERC-4626 facade behaves as spec'd (`previewRedeem(1e18) = 1.1046e18`, `asset() = crvUSD`),
and the fork test settles it either way.

---

## 8. Intermediate amounts as a delta, not a full `balanceOf` *(already merged)*

### Original design

`vaultShares = IERC20(scrvUsdVault).balanceOf(address(this))` and
`crvUsdBal = IERC20(crvUsd).balanceOf(address(this))` read the **entire** balance of the
intermediate token, not the amount the preceding leg produced.

### Evidence

Normal flow leaves zero between calls, so this is correct in the happy path. But any *donated*
intermediate balance is swept through the route and paid out to the next caller. The final
legs already used before/after deltas — the intermediates were the inconsistency.

### Change

Snapshot before the producing leg and subtract. `balanceOf` is retained (it is unavoidable —
Curve's `exchange` is void-return on some pools, so the delta is the only pool-agnostic way to
learn the output); it is simply measured as a delta. Where the call returns the amount
authoritatively (ERC-4626 `deposit`/`redeem`), the return value is used and was already
correct.

Consequence: a donated intermediate now **stays** in the adapter rather than leaking to the
caller — which is what motivated §9.

---

## 9. `TokenHolder` adopted — owner-gated `sweep` *(already merged)*

Because §8 makes donated tokens *stick*, all three executors now inherit bao-base's
`TokenHolder`, giving an owner-gated `sweep(token, amount, receiver)` to recover tokens sent
in by mistake. A bespoke sweep was **not** written — the existing shared mixin is reused.

Knock-on (bao-base): `TokenHolder` inherited `ReentrancyGuardTransientUpgradeable`, which
OpenZeppelin **removed** in newer `contracts-upgradeable` (transient storage is inherently
upgrade-safe, so the upgradeable variant is unnecessary). harbor-swap pins a version that no
longer has it. `TokenHolder` now inherits the non-upgradeable `ReentrancyGuardTransient` —
same `nonReentrant`, transient, storage-safe, no initializer. This also stops it dragging in
an incidental `Initializable`. Storage layout is unaffected, so it is source-compatible only.

---

## 10. TEST DEFECT — the mocks model the code's assumptions, not the dependencies

This is the root cause of §1 surviving a green test suite.

| Mock | Models | Reality |
|---|---|---|
| `MockCurvePool` | `exchange(int128,…)` — *the signature the code calls* | TricryptoLLAMA implements **only** `exchange(uint256,…)` |
| `MockCurvePool` | unknown selector → not modelled | TricryptoLLAMA's `__default__` **accepts it and returns success** |
| `MockCurvePool` | rate `1e18` (1:1) | crvUSD → wstETH ≈ **0.000447** |
| `MockERC4626Vault` | share price 1:1 | scrvUSD ≈ **1.1046** assets/share |
| — | pools always honour `min_dy` | a pool can silently do **nothing** and report success |

Consequences:
- A mock that implements a selector the real pool lacks can only ever **confirm** the bug.
- **The "liar pool" is not hypothetical** — TricryptoLLAMA *is* one for the wrong selector
  (accepts the call, does nothing, returns empty success). The mock must model exactly that.
- 1:1 rates make nearly every assertion `amountOut == amountIn`, which hides unit, scaling and
  decimal errors and reduces the delta accounting to a tautology.
- Because no mock under-delivers silently, the executors' own delta guard (§3) is never
  exercised — the very guard §1 shows to be load-bearing.

### Change

- `MockCurvePool` models **both real families**, and the crypto mode **does not implement the
  `int128` selector** — the mock must reject what the real pool rejects.
- Non-unity, realistic rates throughout (and differing decimals where it matters).
- `MockERC4626Vault` seeded with a non-unity share price.
- A **liar-pool** mode (under-deliver without reverting) to exercise the authoritative guard.

### Note for `CLAUDE.md`

The existing rule says *"a mock must never be **stricter** than the real contract"*. This bug
is the **mirror**: the mock was too **accommodating**. Both directions are defects. The rule
should read: a mock must match the dependency's observable behaviour — neither stricter nor
more permissive — including **which functions it does not have**.

---

## 11. TEST GAP — no fork tests existed

`grep -rl "createSelectFork\|rpcUrl" test/` → nothing. Every test ran against mocks written
from the same assumptions as the code, so no test could ever have discovered §1.

### Change

Fork tests at a **pinned block** (`vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK)`,
block as a single documented constant) so they are deterministic, cacheable and exactly
assertable. Two tiers:

1. **Route/config conformance** — for every configured pool, assert `coins(i) == expectedToken`
   for each index **and** that the pool implements the selector the code will use. This is the
   drift guard that would have caught §1 on day one, and it turns the config docstring's claim
   ("verified on-chain at deployment time") into an executable test.
2. **End-to-end execution** — real fxSAVE/wstETH, both directions, against the real pools and
   the real scrvUSD vault; output within a tight band of an independent on-chain quote
   (`get_dy` / `previewRedeem`); approvals cleared; no residue in the adapter. This also proves
   §7 empirically.

---

## 12. DECISION: 1inch router calldata is **not** decoded *(no change)*

`OneInchSwapper_v1._validateRouterData` validates only the 4-byte selector; the inner
`SwapDescription` (`srcToken`, `dstToken`, `dstReceiver`, `minReturnAmount`) is not checked.

We considered decoding it and asserting `dstReceiver == address(this)`, and **rejected it**.
What actually makes the adapter safe is not the selector check but:
- the approval is scoped to `fromToken` and capped at `amountIn`, so the router can take
  nothing else;
- the output is measured as a `toToken` **delta** and only that delta is paid to
  `msg.sender` — so a diverted `dstReceiver` yields `amountOut == 0` and fails the guard;
- all residual risk falls on `msg.sender`, who supplied the calldata.

The consumer supplies the floor. In the live consumer (`harbor-yield.wip-hytoken`),
`redistribute` passes `minAmountOut = 0` to the adapter *by design* and backstops the whole
composite with an **oracle-derived, non-keeper-settable end-to-end value floor**
(`InsufficientValueOut`), which also catches a diverted `dstReceiver`. Decoding would add
tight coupling to 1inch's v6 struct ABI for no additional protection.

**The selector check should therefore be read as defence-in-depth, not as the thing that makes
this safe.** That is now stated in the docblock.

---

## Related finding, raised separately (consumer repo, not this one)

In `harbor-yield.wip-hytoken`, `SwapLib_v1.swapFloor` **fails open on a zero valuation rate**:
it returns `0` (no floor) when `dstRatePeg == 0`, and computes `0` when `srcRatePeg == 0`. The
same zero-rate collapses `redistribute`'s end-to-end `valueFloor`. Those rates come from live
sources (`Minter.peggedTokenPrice()`, the oracle mid), not from a governance flag — so the
"governance-vetted route" comment on that branch does not describe its actual callers. Handed
off to the consumer repo; it does not affect these executors, but it is the *sole* slippage
protection for swaps made through them, so it is recorded here for completeness.
