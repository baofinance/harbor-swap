# Harbor Admin — `redistribute` Rebalance Spec

Handoff document for building an admin UI that submits manual vault-to-vault rebalances via
`HarborYield_v1.redistribute`. Covers harbor-yield (`multi-asset` branch) and harbor-swap
aggregator adapters (Velora + optional 1inch).

---

## 1. Purpose

`HarborYield_v1.redistribute` moves value **between two managed vaults** inside HY in one atomic tx:

1. Redeem `shares` from `fromVault`
2. Unwind down to `fromToken`
3. Swap `fromToken → toToken` (if different) via named aggregator + `routerData`
4. Wind `toToken` up into `toVault`
5. Enforce end-to-end peg value floor

- **Fee-free** (no hyXXX mint/burn, no mechanism-C fee)
- **Manual-first**: ops wallet or Safe with `REDISTRIBUTOR_ROLE` signs — no keeper required
- **Automation later**: same tx shape from a cron/bot

---

## 2. Contracts & addresses (config per network)

| Item | Source |
|------|--------|
| `HarborYield_v1` | Per peg deploy (e.g. hyETH) |
| `veloraSwapper` | `_predictAddress("veloraSwapper")` from harbor-swap deploy |
| `oneInchSwapper` | `_predictAddress("oneInchSwapper")` (optional; needs 1inch API KYC) |
| Velora router (on-chain) | `0x6A000F20005980200259B80c5102003040001068` |
| 1inch router (on-chain) | `0x111111125421cA6dc452d289314280a0f8842A65` |

**Repo docs:**

- harbor-swap: [`script/DEPLOY_SWAP.md`](script/DEPLOY_SWAP.md) §5
- harbor-swap: [`src/swap/README.md`](src/swap/README.md)
- harbor-yield: `src/interfaces/IHarborYield.sol` (`multi-asset` branch)
- harbor-yield: `test/HarborYieldRedistribute.t.sol` (concrete examples)

---

## 3. Authorization

```solidity
// Caller must have REDISTRIBUTOR_ROLE (or be owner)
HarborYield_v1(hy).hasAnyRole(wallet, HarborYield_v1(hy).REDISTRIBUTOR_ROLE())
```

Grant role to ops Safe / rebalance wallet at deploy. Frontend does **not** need the role for
read-only views; only the signing wallet needs it.

---

## 4. On-chain entrypoint

```solidity
function redistribute(
    address fromVault,
    address fromToken,
    address toVault,
    address toToken,
    uint256 shares,
    uint256 minToAssets,
    address aggregator,   // address(0) if no swap
    bytes calldata routerData
) external;
```

### Two modes (strict coupling)

| Mode | Condition | `aggregator` | `routerData` |
|------|-----------|--------------|--------------|
| **A — Move only (no swap)** | `fromToken == toToken` | `address(0)` | `""` |
| **B — Swap + move** | `fromToken != toToken` | adapter address | non-empty Velora/1inch calldata |

Any other combination **reverts** (`UnexpectedAggregator`, `AggregatorRequired`,
`RouterDataRequired`, etc.).

**There is no fallback to `Swapper_v1` registry** on redistribute. Cross-token moves always
use the named aggregator.

---

## 5. Vault types & valid tokens

### List vaults (read)

```solidity
uint256 n = hy.vaultCount();
for (i = 0; i < n; i++) {
  (address vault, address asset, address oracle, uint64 swapSlippage, bool acceptsInflow) =
    hy.vaultAt(i);
}
```

- `oracle == address(0)` → **AutoCompounder** vault
- `oracle != address(0)` → **Equivalent** vault
- `acceptsInflow == false` → cannot be `toVault` (deprecated / draining)

### Token stacks (what admin can pick)

**AutoCompounder** — unwind/wind rungs (pick one per vault):

```
StabilityPool token  →  haXXX (pegged)  →  wrapped collateral
```

- Swap only happens at **collateral** level (haXXX has no DEX)
- Typical swap path: `wrappedCollateral_A → wrappedCollateral_B` or `wrappedCollateral → equivAsset`

**Equivalent vault** — single rung:

```
vault.asset() only
```

Invalid `fromToken`/`toToken` → `InvalidSwapToken(vault, token)`.

### Other guards

- `fromVault != toVault` (`SameVault`)
- `toVault` must be registered + `acceptsInflow == true` (`VaultNotAcceptingInflow`)
- Mint into stressed minter can revert `RedistributeMintDisallowed` — poll minter health
  off-chain before large AC→AC cross-market moves

---

## 6. Admin UI — recommended screens

### Screen A: Portfolio overview (read-only)

Per vault show:

| Field | How to compute |
|-------|----------------|
| Vault address | `vaultAt(i).vault` |
| Class | AC vs Equivalent (`oracle == 0`) |
| HY shares held | `IERC20(vault).balanceOf(hy)` |
| Assets | `IERC4626(vault).convertToAssets(shares)` |
| Peg value | `assets × hy.fairRate(vault) / 1e18` |
| Accepts inflow | `vaultAt(i).acceptsInflow` |
| Swap slippage tol | `vaultAt(i).swapSlippage` (1e18-scaled) |

**Target weights are off-chain** (governance/config DB). Admin compares current % vs target % to
decide *if* rebalance makes sense. HY does not store weights.

### Screen B: Rebalance form

**Inputs:**

1. Source vault (`fromVault`)
2. Target vault (`toVault`)
3. Shares to move (`shares`) — slider max = `balanceOf(fromVault)` at HY
4. `fromToken` — dropdown from vault stack (§5)
5. `toToken` — dropdown from target vault stack
6. `minToAssets` — minimum assets deposited into `toVault` (strictness knob; `0` = permissive
   for partial fills)
7. Aggregator — `veloraSwapper` or `oneInchSwapper` (only if swap needed)

**Preview panel (before sign):**

- Estimated unwind amount at `fromToken`
- Velora quote: expected `toToken` out, price impact, gas
- Estimated peg value in vs out
- Value floor: `valueIn × (1 - toVault.swapSlippage)`
- Simulate result / revert reason

### Screen C: Confirm & submit

Wallet with `REDISTRIBUTOR_ROLE` signs `hy.redistribute(...)`.

---

## 7. Velora calldata build (default aggregator)

**Base URL:** `https://api.velora.xyz`  
**Docs:** https://developers.velora.xyz/api/velora-api/velora-market-api/master/api-v6.2

### Critical: `userAddress` and `txOrigin`

When building calldata, set:

```
userAddress = veloraSwapper proxy address
txOrigin   = outer transaction sender (keeper / redistributor EOA or Safe)
```

Not HarborYield. Flow is: `EOA/Safe → HY.redistribute → VeloraSwapper.swap() → Augustus`.
The adapter is `msg.sender` to the router (`userAddress`); the signing wallet is `tx.origin`
(`txOrigin`). Velora requires both when an intermediary contract sits between the outer
sender and Augustus.

### Step 1 — Estimate swap input amount

After unwind, HY holds `amount` of `fromToken`. For admin preview (approximate):

- **Equivalent source, `fromToken = asset`:** `amount ≈ IERC4626(fromVault).previewRedeem(shares)`
- **AC source, `fromToken = wrappedCollateral`:** unwind chain is deeper — **always `eth_call`
  simulate** full `redistribute` for exact amount

### Step 2 — Price

Pin Augustus **v6.2** and the two adapters-allowlisted methods. Omitting `version` falls
back to legacy v5 calldata that `VeloraSwapper_v1` rejects.

```http
GET https://api.velora.xyz/prices
  ?srcToken={fromToken}
  &destToken={toToken}
  &amount={amountWei}
  &side=SELL
  &network=1
  &partner=harbor
  &version=6.2
  &includeContractMethods=swapExactAmountIn,swapExactAmountOut
```

Save full `priceRoute` from response.

### Step 3 — Build calldata

```http
POST https://api.velora.xyz/transactions/1
Content-Type: application/json

{
  "priceRoute": { ...verbatim from step 2... },
  "srcToken": "{fromToken}",
  "destToken": "{toToken}",
  "srcAmount": "{amountWei}",
  "userAddress": "{veloraSwapperProxy}",
  "txOrigin": "{outerTransactionSender}",
  "slippage": 100,
  "partner": "harbor"
}
```

Response `data` field → `routerData` for `redistribute`.

### Allowed selectors (on-chain allowlist)

| Selector | Method |
|----------|--------|
| `0xe3ead59e` | `swapExactAmountIn` |
| `0x7f457675` | `swapExactAmountOut` |

Keepers must pin `/prices` with `version=6.2` and
`includeContractMethods=swapExactAmountIn,swapExactAmountOut`. Other Velora entrypoints
revert at the adapter (`DisallowedRouterSelector`).

---

## 8. 1inch calldata (optional alternative)

Use when dev-portal KYC is complete.

- **API:** 1inch Swap API / Pathfinder (requires KYC)
- **Adapter:** `oneInchSwapper` proxy
- **Allowed selector:** `0x07ed2379` (`swap(address,tuple,bytes)`)
- **Router:** `0x111111125421cA6dc452d289314280a0f8842A65`

`routerData` must be built for the same adapter address passed to `redistribute`.

---

## 9. Example calls (from tests)

### A — AC → AC, same peg token (no swap)

```solidity
hy.redistribute(
  acVault1,
  peggedToken,      // haETH
  acVault2,
  peggedToken,      // haETH
  shares,
  0,                // minToAssets
  address(0),
  ""
);
```

### B — AC → equivalent (swap via aggregator)

```solidity
hy.redistribute(
  acVault,
  wrappedCollateral,
  equivVault,
  equivAsset,
  shares,
  minToAssets,
  veloraSwapper,
  veloraCalldata    // from Velora POST /transactions/1
);
```

---

## 10. Slippage & safety model

HY does **not** rely on adapter `minAmountOut` (passed as `0` internally). Guards:

1. **`minToAssets`** — minimum assets landed in `toVault`
2. **End-to-end peg value floor:**

   ```
   valueOut >= valueIn × (1 - toVault.swapSlippage / 1e18)
   ```

   where `valueIn` = peg value of redeemed `shares` (captured before unwind, depeg-aware via
   `fairRate`)

3. **Partial fills** — unspent `fromToken` is **rewound into `fromVault`**, not stranded.
   Event: `RedistributeRefundRewound`.

**Admin recommendation:** always `eth_call` simulate before submit; show revert reason in UI.

---

## 11. Revert errors (show in UI)

| Error | Meaning |
|-------|---------|
| `SameVault` | Source = target |
| `AggregatorRequired` | Different tokens but no aggregator |
| `RouterDataRequired` | Different tokens but empty calldata |
| `UnexpectedAggregator` | Same token but aggregator provided |
| `UnexpectedRouterData` | Same token but calldata provided |
| `VaultNotAcceptingInflow` | Target deprecated |
| `InvalidSwapToken` | Token not on vault stack |
| `InsufficientToAssets` | Landed less than `minToAssets` |
| `InsufficientValueOut` | Broke end-to-end peg value floor |
| `RedistributeMintDisallowed` | Target minter in mint-disallow band |
| `DisallowedRouterSelector` | Wrong aggregator/calldata pairing |

---

## 12. Pre-submit checklist

```
□ Caller has REDISTRIBUTOR_ROLE
□ fromVault != toVault
□ toVault.acceptsInflow == true
□ HY holds >= shares of fromVault
□ fromToken / toToken valid for respective vault stacks
      □ If swap: aggregator matches calldata source (Velora calldata → veloraSwapper)
      □ Velora userAddress = veloraSwapper proxy
      □ Velora txOrigin = outer transaction sender (keeper / redistributor)
□ eth_call simulate succeeds
□ minToAssets set appropriately (0 for partial-fill tolerance, >0 for strict)
□ Target minter healthy (if AC target, cross-market)
```

---

## 13. Suggested API shape (your backend)

```
GET  /api/harbor/:hyAddress/vaults          → vault list + balances + peg values
GET  /api/harbor/:hyAddress/vault/:v/tokens → valid fromToken/toToken options
POST /api/harbor/redistribute/preview       → simulate + Velora quote
POST /api/harbor/redistribute/submit        → returns unsigned tx data (or wallet signs client-side)
```

`preview` should:

1. Resolve vault metadata from chain
2. Estimate unwind amount (or simulate full redistribute)
3. Call Velora `GET /prices` + `POST /transactions/1`
4. `eth_call` `redistribute` with returned calldata
5. Return quote + simulation status to UI

---

## 14. What is NOT needed

| Not required | Why |
|--------------|-----|
| Always-on keeper | Manual wallet can call `redistribute` |
| 1inch | Velora is default (no KYC) |
| On-chain weight registry | Weights are off-chain config |
| `Swapper_v1` route for redistribute | Aggregator-only for cross-token |

---

## 15. Minimal v1 scope

**Ship first:**

1. Vault overview (reads only)
2. Manual rebalance form
3. Velora quote + simulate
4. Single-wallet submit (ops Safe)

**Defer:**

- Automated drift detection / cron
- 1inch path in UI
- Multi-peg dashboard
