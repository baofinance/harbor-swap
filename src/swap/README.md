# Harbor Swap Adapter

Self-contained swap layer used by `HarborYield_v1` and (in future) other Harbor products.

This subtree is a **split-ready package**: it has no imports from `HarborYield_v1` or any
other yield-side contract. When a second consumer appears (minter, another yield variant,
fee router) or audit/compliance requires a separately-versioned artifact, this directory is
extracted to a standalone `harbor-swapadapter` repo via
`git filter-repo --subdirectory-filter src/swap`. Until then it lives here.

Imports inside the subtree use the `@harbor-swap/` remap defined in
[`foundry.toml`](../../foundry.toml); consumers (e.g. `HarborYield_v1`, deploy scripts,
tests) also import via `@harbor-swap/...` so the eventual repo split is a no-op for source
code.

## Layout

```
src/swap/
  Swapper_v1.sol                    Pure route registry (from, to) -> {executor, feeRatio}
  interfaces/
    ISwapper.sol                    Read API: getRoutesFrom (batch) + getRoute (single pair)
    ISwapperConfig.sol              Admin API: setRoute + RouteUpdated event
    ISwapExecutor.sol               DEX-specific execution API: swap (no calldata)
  executors/
    UniV3Swapper_v1.sol             Uniswap v3 executor (exactInput, multi-hop paths)
    CurveSwapper_v1.sol             Curve StableSwap executor (per-pair pool + int128 i/j +
                                    exchange / exchange_underlying selector)
    BalancerSwapper_v1.sol          Balancer V2 single-swap executor (immutable Vault,
                                    per-pair bytes32 poolId, GIVEN_IN semantics)
    FxSaveWstEthSwapper_v1.sol      Composite fxSAVE → wstETH (Curve + scrvUSD vault + Curve)
  config/
    ConfigFxSaveWstEthRoute_ETH_mainnet.sol  Mainnet route constants for FxSaveWstEthSwapper
  aggregator/
    IAggregatorSwapper.sol          swap(from, to, in, minOut, bytes) interface
    OneInchSwapper_v1.sol           Fixed-router (1inch v6) adapter, calldata-driven, refund-on-partial-fill
```

Tests mirror the source layout under `test/swap/` and use the `@harbor-swap-test/` remap.
Cross-cutting mocks (`MockSwapper`, `MockUniV3Router`, `MockRawRouter`) stay in `test/mocks/`.

## Two-mode design

Harbor swap supports two distinct execution paths, chosen per call site by the consumer:

### 1. Direct executor (urgent, hot path)

`HarborYield_v1.distribute()` and other latency- or peg-critical flows do:

1. One batched `ISwapper.getRoutesFrom(from, targets)` view call.
2. For each target with `available == true`, call `ISwapExecutor(swapExecutor).swap(from, to,
   amountIn, minAmountOut)` **directly** — no per-tx calldata.

Properties:

- Predictable gas (no off-chain dependency).
- All routing parameters live in executor storage:
  - **UniV3**: encoded `bytes` path (single- or multi-hop) per pair via `setPath`.
  - **Curve**: `{pool, int128 i, int128 j, bool useUnderlying}` per pair via `setRoute`.
    Pool is the approval target (no canonical Curve router across chains).
  - **Balancer V2**: `bytes32 poolId` per pair via `setRoute`; the immutable Vault is
    the single approval target for every Balancer swap.
  - **Composite routes** (e.g. fxSAVE → wstETH): dedicated executors such as
    `FxSaveWstEthSwapper_v1` with route constants in `config/` libraries; registered
    in `Swapper_v1` via `setRoute` at deploy time.
- Trust boundary: only the registry's stored executor address is called; executors only
  call their immutable router/vault (Uni, Balancer) or the governance-configured pool
  storage (Curve).
- Curve's low-level call pattern is intentionally agnostic to legacy void-return pools
  (e.g. 3pool) vs newer uint256-return variants; amountOut is always reconciled by
  post-call `balanceOf` delta, which also covers per-pool fees.

### 2. Aggregator (low-urgency)

For long-tail routes, multi-hop graphs, and slow rebalances `aggregator/OneInchSwapper_v1`
accepts opaque `bytes` calldata built off-chain by a keeper. It is exposed via
`HarborYield_v1.executeAggregatorSwap` (role-gated to `AGGREGATOR_ROLE`) and never invoked
from the `distribute()` loop, so untrusted calldata never enters peg-critical code paths.

Flow:

1. Keeper builds router calldata off-chain (1inch API / pathfinder) and submits via HY.
2. HY pulls `amountIn` from its idle balance, approves `OneInchSwapper_v1` for exactly
   `amountIn`, and forwards the call.
3. `OneInchSwapper_v1` pulls the input, approves its immutable router (1inch v6), invokes
   `router.call(routerData)`, resets the router allowance to zero, then verifies output
   via `balanceOf(toToken)` delta against `minAmountOut`.
4. Any unspent `fromToken` (1inch `_PARTIAL_FILL` flag) is refunded; remaining proceeds
   land back in HY for the next `distribute()` to deposit.

Properties:

- Arbitrary routes without deploying a new executor per pool.
- Immutable router address (no caller-supplied target).
- Two-stage approve / call / zero approval flow at both HY and adapter layers.
- Slippage enforced twice: by the router's own minReturn inside the calldata and by the
  adapter's post-call balance-delta check against `minAmountOut`.
- Role gate (`AGGREGATOR_ROLE`) lives on `HarborYield_v1`; the adapter itself is open
  because it only ever spends `msg.sender`'s pre-approved balance.

### HarborYield routing (hyETH example)

When a collateral AutoCompounder calls `HarborYield_v1.distribute()` with fxSAVE rewards:

1. **Phase 2 — compound:** If the Minter fee is within the swap-fee threshold, fxSAVE is
   compounded into **haETH** and redeposited into the **collateral stability pool** (no swap).
2. **Phase 3 — equiv vault:** Residual fxSAVE is swapped to **wstETH** via the direct executor
   registered in `Swapper_v1` (production ETH: `FxSaveWstEthSwapper_v1`) and deposited into
   the wstETH equivalent vault.

`distribute()` **never** calls the 1inch aggregator. Keepers use
`executeAggregatorSwap` separately for discretionary rebalances, idle balances, or routes
that are not registered in `Swapper_v1`.

## Monitoring and config events

Route changes emit events for indexers and deploy verification:

| Contract | Event | When |
|----------|-------|------|
| `Swapper_v1` | `RouteUpdated(from, to, executor, feeRatio)` | `setRoute` (executor `address(0)` = cleared) |
| `UniV3Swapper_v1` | `PathSet(from, to, path)` | `setPath` |
| `CurveSwapper_v1` | `RouteSet(...)` | `setRoute` |
| `BalancerSwapper_v1` | `RouteSet(...)` | `setRoute` |
| `OneInchSwapper_v1` | `AggregatorSwap(...)` | each `swap` |

Off-chain tooling can also call `ISwapper.getRoute(from, to)` for a single pair without
building a one-element `targets` array.

## Public interface contract

External code should depend on the **interfaces only**:

- [`ISwapper`](interfaces/ISwapper.sol) — read side. `getRoutesFrom` (batch) and `getRoute`
  (single pair).
- [`ISwapperConfig`](interfaces/ISwapperConfig.sol) — admin side. Per-pair `setRoute` and
  `RouteUpdated` event.
- [`ISwapExecutor`](interfaces/ISwapExecutor.sol) — execution side. Stable four-argument
  signature; new DEX adapters implement this.

`Swapper_v1` and the executor implementations are upgradeable (UUPS, ERC-7201 storage
namespace); proxy addresses are stable across upgrades.

## Threat model

`Swapper_v1`:

- Holds no funds and executes no swaps. Compromise of `ROUTE_SETTER_ROLE` can redirect
  callers to a malicious executor but cannot directly drain HY because executors only act
  on tokens HY explicitly transfers + approves per call.

Executors (`UniV3Swapper_v1`, `CurveSwapper_v1`, `BalancerSwapper_v1`, `FxSaveWstEthSwapper_v1`):

- **Approval target**:
  - `UniV3Swapper_v1`: immutable `ROUTER` (Uniswap V3 SwapRouter) set at construction.
  - `BalancerSwapper_v1`: immutable `VAULT` (Balancer V2 Vault) set at construction;
    `ConfigBalancer.BALANCER_V2_VAULT` provides the canonical cross-chain singleton.
    **Single-hop only** — one `Vault.swap` per call; multi-pool graphs use the aggregator
    or a dedicated composite executor.
  - `CurveSwapper_v1`: per-pair pool address from governance-gated storage. Never
    caller-supplied; setter is `onlyOwnerOrRoles(ROUTE_SETTER_ROLE)`. **Single pool per call.**
  - `FxSaveWstEthSwapper_v1`: hardcoded mainnet venues in
    `config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol` (two Curve pools + scrvUSD vault).
    **Intermediate slippage:** legs 1–2 use Curve `min_dy = 0`; only final wstETH output
    is bounded by `minAmountOut` from HarborYield (oracle floor). Sandwich risk on
    intermediate legs is accepted for this peg-critical route; monitor pool liquidity and
    consider keeper/aggregator rebalances for large notionals.
- Pull `fromToken` from `msg.sender`, swap, deliver `toToken` to `msg.sender`.
- Approval to the router/vault/pool is reset to zero after every swap.
- Reentrancy guarded (transient storage) where the venue could call back (Curve pools
  with ERC-777/hook coins, ERC-1363 transferAndCall paths, etc.).
- Slippage enforced **twice** — by the venue's own minOut (`amountOutMinimum`, `min_dy`,
  Balancer `limit`) and by a post-call `balanceOf` delta check. Curve's path uses balance
  delta as the primary slippage signal since some legacy pools return void.

Aggregator (`OneInchSwapper_v1`):

- Immutable router (1inch AggregationRouterV6 on production; constructor arg overridable
  for tests / future routers). Caller supplies opaque calldata; recipient and amounts are
  encoded in that calldata. The adapter only enforces slippage by balance delta and resets
  the router allowance to zero — it does **not** validate the calldata, so the call site
  must hold `AGGREGATOR_ROLE` on `HarborYield_v1` (or own the consumer outright) and
  provide vetted keeper-built routes.
- Unspent `fromToken` after a partial fill is refunded to `msg.sender` (HY), so no input
  can accrue inside the adapter between calls.
- The adapter is open-access (no role gate on `swap`) because it operates purely on
  `msg.sender`'s pre-approved balance; the authorization seam lives in the consumer.

## Consumer integration

All production proxy deployments go through **BaoFactory CREATE3** via
[`script/src/contracts/Swapper.sol`](../../script/src/contracts/Swapper.sol) (inherits
[`HarborDeployer`](https://github.com/baofinance/harbor) → `_deployProxyAndRecord`). See
[`script/DEPLOY_SWAP.md`](../../script/DEPLOY_SWAP.md) for cross-repo prerequisites
(harbor Phase 1a, harbor-price-aggregators Phase 1b), operator setup, and salt keys.

Deploy helpers:

- `deploySwapper(state)` — deploys the `Swapper_v1` registry (peg-agnostic, shared).
- `deployUniV3Swapper(state)` — deploys `UniV3Swapper_v1` (router from `_uniV3RouterAddress()`).
- `deployCurveSwapper(state)` — deploys `CurveSwapper_v1`. Curve has no canonical router
  across chains, so pool addresses are configured per-pair after deployment via
  `CurveSwapper_v1.setRoute(from, to, pool, i, j, useUnderlying)`.
- `deployBalancerSwapper(state)` — deploys `BalancerSwapper_v1` with the canonical
  Balancer V2 Vault constant from [`ConfigBalancer`](../../script/src/config/ConfigBalancer.sol).
  An overload accepting an explicit Vault address is used by unit tests.
- `deployOneInchSwapper(state)` — deploys `OneInchSwapper_v1` with the canonical 1inch v6
  router constant from [`ConfigOneInch`](../../script/src/config/ConfigOneInch.sol). An
  overload accepting an explicit router address is used by unit tests.
- `deployFxSaveWstEthSwapper(state)` — deploys `FxSaveWstEthSwapper_v1` with the mainnet
  fxSAVE → wstETH route compiled into the implementation
  ([`ConfigFxSaveWstEthRoute_ETH_mainnet`](config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol)).
  Used by [`Deploy_ETH_HarborYield`](../../script/src/Deploy_ETH_HarborYield.sol) for hyETH.

Each peg-specific deployer (e.g.
[`Deploy_ETH_HarborYield`](../../script/src/Deploy_ETH_HarborYield.sol)) overrides
`HarborYieldDeployer._configureSwapRoutes` to do two layers of wiring per pair:

1. Configure the executor itself (each DEX has its own native setter):
   - `UniV3Swapper_v1.setPath(from, to, encodedPath)`
   - `CurveSwapper_v1.setRoute(from, to, pool, i, j, useUnderlying)`
   - `BalancerSwapper_v1.setRoute(from, to, poolId)`
2. Register the executor in the registry via
   `ISwapperConfig.setRoute(from, to, executorProxy, feeRatio)` so `Swapper_v1` knows
   which executor to dispatch to for that pair.

Aggregator wiring follows the same pattern but bypasses the registry: call
`deployOneInchSwapper(state)`, then `IHarborYield.setAggregatorSwapper(swapper)` to point
HY at it, and finally `grantRoles(keeper, HarborYield_v1.AGGREGATOR_ROLE())` for each
keeper allowed to trigger `executeAggregatorSwap`.

**Deploy runbook:** step-by-step wiring, mainnet pool caveats, role grants, and verification
checklist live in [`script/DEPLOY_SWAP.md`](../../script/DEPLOY_SWAP.md).

## When this becomes its own repo

Trigger criteria (see plan document):

1. A second Harbor product imports `@harbor-swap/...`.
2. Audit / compliance requires a separately-versioned, separately-deployed artifact.
3. Subtree size starts dominating this repo's review scope.

Extract recipe at that point:

```bash
git clone harbor-yield-1 harbor-swapadapter
cd harbor-swapadapter
git filter-repo --subdirectory-filter src/swap
# add foundry.toml, lib/ (forge-std, OZ, solady, harbor for @bao/HarborOwnableRoles),
# README, slither config; publish; back in harbor-yield-1 add as
# lib/harbor-swapadapter submodule and repoint the @harbor-swap/ remap.
```
