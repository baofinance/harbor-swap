# Swap deploy and route-configuration runbook

Operational guide for deploying the Harbor swap stack from **this repo**
([baofinance/harbor-swap](https://github.com/baofinance/harbor-swap)). For architecture,
threat model, and interface contracts see [`src/swap/README.md`](../src/swap/README.md).

**Production rule:** all swap **proxies** deploy through [**BaoFactory**](https://github.com/baofinance/harbor)
CREATE3 via the deploy helpers in [`script/src/contracts/Swapper.sol`](src/contracts/Swapper.sol) —
never hand-roll `new Swapper_v1` + ERC1967Proxy for mainnet. Implementation contracts are
deployed with `new` in-script; UUPS proxies are always factory-deployed at deterministic salts.

---

## Repo scope

| Repo | Delivers |
|------|----------|
| **harbor-swap** (this repo) | `Swapper_v1`, direct executors, `VeloraSwapper_v1`, `OneInchSwapper_v1`, deploy scripts |
| [baofinance/harbor](https://github.com/baofinance/harbor) | Phase 1a — Minter, SP, SPM; `HarborDeployer`, BaoFactory (`@harbor-script/`) |
| [baofinance/harbor-price-aggregators](https://github.com/baofinance/harbor-price-aggregators) | Phase 1b — oracles at CREATE3 addresses |
| **Harbor Yield consumer repo** (separate) | `HarborYield_v1`, ACs, equiv vaults; imports `@harbor-swap/`; full-stack HY fork/integration tests |

Harbor Yield wiring (`_configureSwapRoutes` and keeper `REDISTRIBUTOR_ROLE` grants)
lives in the consumer repo. This runbook covers swap-stack deploy and route configuration;
§5 describes how the consumer connects the aggregator adapter.

---

## 0. Prerequisites — BaoFactory CREATE3 and cross-repo deploy

Swap deployment is **Phase 2a** of the Harbor stack. It assumes Phase 1 is already live.

### Cross-repo ordering

| Phase | Repo | Delivers (swap-relevant) |
|-------|------|--------------------------|
| **1a** | [baofinance/harbor](https://github.com/baofinance/harbor) | `Minter_v3`, `StabilityPool_v3`, `StabilityPoolManager_v2` — AC compound + `distribute()` source |
| **1b** | [baofinance/harbor-price-aggregators](https://github.com/baofinance/harbor-price-aggregators) | `IWrappedPriceOracle` impls at CREATE3 addresses (e.g. `Aggregator_stETH_ETH_mainnet` for wstETH equiv vault) |
| **2a** | **harbor-swap** (this repo) | `Swapper_v1`, executors, aggregator adapter |
| **2b** | Harbor Yield consumer repo | `HarborYield_v1`, ACs, equiv adapters; registry wiring + keeper `REDISTRIBUTOR_ROLE` grants |

Phase 1a and 1b are independent of each other; **both must complete before Phase 2**.

Oracle addresses from harbor-price-aggregators are predictable from the same salt scheme
BaoFactory uses. Example (ETH peg): wstETH equivalent vault reads
`Aggregator_stETH_ETH_mainnet` deployed by harbor-price-aggregators — see that repo's deploy
scripts. Fork integration tests that mock oracles at `_predictAddress(...)` live in the
Harbor Yield consumer repo, not in harbor-swap.

### How BaoFactory deployment works

All harbor-swap deploy scripts inherit [`HarborDeployer`](https://github.com/baofinance/harbor/blob/harbor-yield/script/src/HarborDeployer.sol)
(from `lib/harbor/script/` via `@harbor-script/`). Swap proxies use:

```solidity
// script/src/contracts/Swapper.sol — every executor + registry
proxy = _deployProxyAndRecord(stateData, "uniV3Swapper", impl, initData);
```

`_deployProxyAndRecord` (in `HarborFactoryDeployer` / `HarborDeployer`) calls
`IBaoFactory(baoFactory()).deploy(...)` with a CREATE3 salt derived from
`_saltString(key)`. The resulting address is **deterministic** from `{saltPrefix}::{key}`.

**Address prediction before deploy:**

```solidity
_setSaltPrefix("harbor_v1::eth");
address swapper = _predictAddress("swapper");       // valid before deploySwapper runs
address uniV3   = _predictAddress("uniV3Swapper");
```

The Harbor Yield consumer passes `swapper = _predictAddress("swapper")` as an immutable
when deploying `HarborYield_v1`.

### Operator and ownership

1. Deploy script runner must be a **BaoFactory operator** for the duration of the script:
   ```solidity
   vm.prank(IBaoFactory(factory).owner());
   IBaoFactory(factory).setOperator(deployScript, expiry);
   ```
   Production: Safe or ops key granted operator by factory owner before running the script.

2. Proxies initialize with `(deployerOwner, pendingOwner)` — deploy script is temporary
   owner, then `_transferAllOwnerships()` hands control to the Safe.

3. Route wiring (`setRoute`, `setPath`) runs **while the deploy script still owns** the
   contracts, inside the consumer's `_configureSwapRoutes` hook or immediately after deploy,
   before ownership transfer.

### Salt keys (swap stack)

Full salt = `{saltPrefix}::{key}`. Swap contracts use **peg-agnostic** keys (shared across
HY peg instances on the same network):

| Key | Proxy via `_deployProxyAndRecord` |
|-----|-----------------------------------|
| `swapper` | `Swapper_v1` registry |
| `uniV3Swapper` | `UniV3Swapper_v1` |
| `curveSwapper` | `CurveSwapper_v1` |
| `balancerSwapper` | `BalancerSwapper_v1` |
| `veloraSwapper` | `VeloraSwapper_v1` |
| `oneInchSwapper` | `OneInchSwapper_v1` |
| `fxSaveWstEthSwapper` | `FxSaveWstEthSwapper_v1` (ETH mainnet fxSAVE ↔ wstETH composite) |
| `fxSaveWbtcSwapper` | `FxSaveWbtcSwapper_v1` (fxSAVE ↔ WBTC) |
| `fxSaveLbtcSwapper` | `FxSaveLbtcSwapper_v1` (fxSAVE ↔ LBTC) |
| `fxSaveEurcSwapper` | `FxSaveEurcSwapper_v1` (fxSAVE → EURC) |
| `wstEthWbtcSwapper` | `WstEthWbtcSwapper_v1` (wstETH → WBTC) |
| `wstEthLbtcSwapper` | `WstEthLbtcSwapper_v1` (wstETH → LBTC) |

Per-peg HY uses `{pegKey}::harborYield`, `{pegKey}::beacon`, etc. — configured in the
Harbor Yield consumer repo.

### What not to do on mainnet

- Do **not** deploy swap proxies outside [`Swapper.sol`](src/contracts/Swapper.sol) helpers.
- Do **not** hard-code proxy addresses in source — use `_predictAddress` + config mixins.
- Do **not** wire registry routes to an EOA or unverified contract — only CREATE3 executor
  proxies registered via `ISwapperConfig.setRoute`.
- Do **not** skip harbor-price-aggregators oracles for equiv vaults that reference them in
  deploy config — registration will revert on peg-drift checks or valuation will be wrong.

### Tests mirror production

[`BaoTest._ensureBaoFactory()`](../lib/harbor/lib/bao-base/test/) bootstraps Nick's Factory →
BaoFactory proxy → v1 upgrade. Swap unit tests under `test/swap/` call the same
`deploySwapper` / `deployUniV3Swapper` paths as production via CREATE3. Override
`deploySwapperImplementation()` to inject `MockSwapper` without bypassing the factory.

**Test scope in this repo:** mock-based unit tests under `test/swap/` plus pinned mainnet
fork tests under `test/swap/fork/` (require `MAINNET_RPC_URL`):

```bash
yarn test --match-path "test/swap/**"                # unit + fork; FAILS without MAINNET_RPC_URL
yarn test --match-path "test/swap/executors/**"      # unit only
```

The fork tests do not skip when `MAINNET_RPC_URL` is unset — `ForkTestBase._forkMainnet` calls
`vm.createSelectFork(vm.rpcUrl("mainnet"))` unguarded, and `foundry.toml` resolves the `mainnet`
endpoint from that variable, so they fail. That is deliberate: a fork test that quietly skips
reports green while proving nothing. Set the variable (see `.env.example`) or match a path that
excludes `test/swap/fork/`.

Full ETH-stack HarborYield integration (registry + oracles + `HarborYield_v1`) lives in the
Harbor Yield consumer repo.

---

## 1. Which path to use

| Scenario | Path | Entrypoint | When |
|----------|------|------------|------|
| **Urgent / peg-critical** | Direct executor | `HarborYield_v1.distribute()` → `ISwapExecutor.swap` | Residual wCOLn routing during AC distribution; must be predictable gas, no off-chain router dependency |
| **Low-urgency / long-tail** | Aggregator (Velora Augustus v6.2) | `HarborYield_v1.redistribute` | Scheduled rebalances, illiquid pairs, multi-pool Curve/Balancer chains, exotic venues |

**Rule:** `distribute()` never calls the aggregator. Untrusted keeper calldata stays out of
the hot path. `redistribute` unwinds source-vault shares, swaps through the keeper's aggregator, and winds the
proceeds straight into the target vault in one atomic call — no idle balance sits at HY between steps.

---

## 2. Contract inventory

All swap proxies share the deploy script salt prefix (e.g. `harbor_v1::eth::`) and are
**peg-agnostic** — one set per network, shared across HY peg instances on that network.

| Salt key | Contract | Purpose |
|----------|----------|---------|
| `swapper` | `Swapper_v1` | Route registry: `(from, to) → {executor, routeCostRatio}` |
| `uniV3Swapper` | `UniV3Swapper_v1` | Uniswap v3 `exactInput` (single- or multi-hop) |
| `curveSwapper` | `CurveSwapper_v1` | Curve StableSwap `exchange` / `exchange_underlying` |
| `balancerSwapper` | `BalancerSwapper_v1` | Balancer V2 Vault single-swap |
| `veloraSwapper` | `VeloraSwapper_v1` | Velora Augustus v6.2 fixed-router adapter (aggregator only) |
| `oneInchSwapper` | `OneInchSwapper_v1` | 1inch v6 fixed-router adapter (aggregator only) |
| `fxSaveWstEthSwapper` | `FxSaveWstEthSwapper_v1` | fxSAVE ↔ wstETH composite (Curve stables + UniV3 ETH hop; ETH mainnet) |

Deploy helpers live in [`script/src/contracts/Swapper.sol`](src/contracts/Swapper.sol).

Chain constants:

| Constant | Address | File |
|----------|---------|------|
| Uniswap v3 SwapRouter (mainnet) | `0xE592427A0AEce92De3Edee1F18E0157C05861564` | [`ConfigSwap_ETH_mainnet.sol`](src/config/ConfigSwap_ETH_mainnet.sol) |
| Balancer V2 Vault (all major chains) | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` | [`ConfigBalancer.sol`](src/config/ConfigBalancer.sol) |
| Velora Augustus v6.2 (same address on all Velora chains) | `0x6A000F20005980200259B80c5102003040001068` | [`ConfigVelora.sol`](src/config/ConfigVelora.sol) |
| 1inch AggregationRouterV6 (CREATE2, all major chains) | `0x111111125421cA6dc452d289314280a0f8842A65` | [`ConfigOneInch.sol`](src/config/ConfigOneInch.sol) |

Curve has **no canonical router** — each pair points at a specific pool contract.

---

## 3. Deploy order (Phase 2a — via BaoFactory)

Swap deployment is orchestrated by [`HarborSwapDeployStack`](src/HarborSwapDeployStack.sol) (`deploySwapStack`).

| Script | When | What it deploys |
|--------|------|-----------------|
| [`Deploy_Swap.s.sol`](../Deploy_Swap.s.sol) | Swap stack only, shared infra before any HY peg | Registry + UniV3 + Curve + Balancer + Velora + 1inch + fxSAVE→wstETH |

**Standalone swap stack** (this repo):

```bash
script/run-script Deploy_Swap --salt harbor_v1 --network mainnet
```

[`Deploy_Swap.s.sol`](../Deploy_Swap.s.sol) calls [`Deploy_Swap.deploySwapInfrastructure`](src/Deploy_Swap.sol),
which runs:

```
Phase 2a — harbor-swap deploy script (BaoFactory operator)
  1. _setSaltPrefix(saltPrefix)
  2. deploySwapStack(state, fullOpts)  → swapper + uniV3 + curve + balancer + velora + oneInch
  3. deployHyPegEquivExecutors(state) → fxSAVE/wstETH/BTC/EURC composites
  4. configureHyPegEquivRoutes()      → registry Layer 2 (+ UniV3 wstETH→EURC path)
  5. flush + _transferAllOwnerships()  → Safe receives proxy ownership
```

Optional executors in `deploySwapStack` are controlled by `SwapDeployOptions`
(`deployCurve`, `deployBalancer`, `deployVelora`, `deployOneInch`). `Deploy_Swap` enables all four.
Use `_veloraAggregatorDeployOptions()` when only the primary aggregator is needed.

**hy peg-equiv direct routes** (into peg-equiv; reverse/remint via Velora `redistribute`):

| Pair | Executor |
|------|----------|
| fxSAVE ↔ wstETH | `FxSaveWstEthSwapper_v1` |
| fxSAVE ↔ WBTC | `FxSaveWbtcSwapper_v1` |
| fxSAVE ↔ LBTC | `FxSaveLbtcSwapper_v1` |
| fxSAVE → EURC | `FxSaveEurcSwapper_v1` |
| wstETH → WBTC | `WstEthWbtcSwapper_v1` (UniV3 via WETH) |
| wstETH → LBTC | `WstEthLbtcSwapper_v1` (UniV3 via WETH→WBTC) |
| wstETH → EURC | `UniV3Swapper_v1` (WETH → USDC → EURC) |

**Harbor Yield consumer repo** then deploys HY infrastructure (Phase 2b) and wires routes
via `_configureSwapRoutes` — typically registry + UniV3 only on default deploy, or the full
stack when `runFull` is used. See the consumer repo's deploy scripts for peg-specific flow.

**Immutables wired at deploy time:** executor routers/Vaults are constructor args on impl
deployment (`UniV3Swapper_v1(router)`, `BalancerSwapper_v1(BALANCER_V2_VAULT)`); the **proxy**
address is what gets registered in `Swapper_v1`. The consumer passes
`swapper = _predictAddress("swapper")` into `HarborYield_v1` at construction.

**Important:** route setters require owner (or delegated `*_SETTER_ROLE`). Wire routes while
the deploy script still owns the contracts, before `_transferAllOwnerships()`.

---

## 4. Direct routes — two-layer wiring

Every direct pair requires **two** on-chain writes. Order matters: configure the executor
first, then register it in the registry.

### Layer 1 — Executor-native config

| DEX | Setter | Parameters |
|-----|--------|------------|
| UniV3 | `UniV3Swapper_v1.setPath(from, to, path)` | `path` = `abi.encodePacked(tokenIn, fee, tokenOut)` for single-hop (43 bytes), or `tokenIn, fee1, mid, fee2, tokenOut` for multi-hop (66+ bytes) |
| Curve | `CurveSwapper_v1.setRoute(from, to, pool, i, j, useUnderlying)` | `i`/`j` = int128 coin indices in the pool; `useUnderlying` = true for lending/meta pools |
| Balancer | `BalancerSwapper_v1.setRoute(from, to, poolId)` | `poolId` = bytes32 from Balancer UI or `Vault.getPool(poolAddress)` |

Clear a route: UniV3 `setPath(from, to, "")`; Curve `setRoute(..., pool=0, ...)`; Balancer
`setRoute(from, to, bytes32(0))`.

### Layer 2 — Registry

```solidity
ISwapperConfig(swapper).setRoute(fromToken, toToken, executorProxy, routeCostRatio);
```

- `executorProxy` = CREATE3 address of the executor (e.g. `_predictAddress("uniV3Swapper")`).
- `routeCostRatio` = expected route cost (fee + expected slippage) as a 1e18-scaled ratio
  (e.g. `3e15` = 0.3%). Surfaced on `RouteInfo.routeCostRatio`. HarborYield reads this in
  `distribute()` as the minting threshold — configure it to cover the real pool fee **and**
  expected slippage (do not use the pool fee alone), so residual swaps only run when
  economically sensible.
- Pass `executor = address(0)` to remove a registry entry.

### Example — ETH peg fxSAVE ↔ wstETH (FxSaveWstEthSwapper)

Production ETH wiring uses a **dedicated composite executor** (not UniV3). One proxy handles
both directions; register each pair separately in `Swapper_v1`:

```solidity
// Deploy (once per network, shared across pegs):
deployFxSaveWstEthSwapper(state);
address fxSaveWstEth = _predictAddress("fxSaveWstEthSwapper");

// Layer 2 (registry) — `Deploy_Swap.configureFxSaveWstEthRoutes()` on standalone deploy,
// or equivalent in consumer _configureSwapRoutes:
ISwapperConfig(swapper).setRoute(FXSAVE, WSTETH, fxSaveWstEth, FXSAVE_TO_WSTETH_ROUTE_COST_RATIO);
ISwapperConfig(swapper).setRoute(WSTETH, FXSAVE, fxSaveWstEth, WSTETH_TO_FXSAVE_ROUTE_COST_RATIO);
```

Route-cost constants: [`ConfigSwap_ETH_mainnet`](src/config/ConfigSwap_ETH_mainnet.sol)
(`FXSAVE_TO_WSTETH_ROUTE_COST_RATIO`, `WSTETH_TO_FXSAVE_ROUTE_COST_RATIO`). On pegs where wrapped
collateral differs from mainnet `FXSAVE`, use the peg's wrapped collateral address instead of
`FXSAVE` in `setRoute` (executor impl still uses mainnet venue constants).

**No Layer 1 config** — venues and coin indices are compiled into
[`ConfigFxSaveWstEthRoute_ETH_mainnet`](../src/swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol)
and baked into the implementation.

**Upgrading `FxSaveWstEthSwapper_v1`:** edit the config library + deploy a new implementation,
then UUPS-upgrade the `fxSaveWstEthSwapper` proxy (or deploy a new proxy and update
`Swapper_v1.setRoute`). Re-run fork validation on the composite path before mainnet execution.
Successful swaps emit `FxSaveWstEthSwap(caller, from, to, amountIn, intermediateAmount)`
where `intermediateAmount` is crvUSD after vault redeem (forward) or after USDC→crvUSD
(reverse).

**Slippage note (intentional tradeoff):** intermediate Curve / Uni legs use a zero venue
floor; only final output is bounded by HarborYield's oracle floor (`minAmountOut`). Sandwich
risk on intermediate legs is accepted for this peg-critical route. Monitor pool liquidity for
large residual fxSAVE during `distribute()` Phase 3; consider keeper/aggregator rebalances for
large notionals.

### Example — generic UniV3 pair (Layer 1 + Layer 2)

For pairs wired through `UniV3Swapper_v1`:

```solidity
// Layer 2 (registry):
ISwapperConfig(swapper).setRoute(fromToken, toToken, uniV3Swapper, routeCostRatio);

// Layer 1 (UniV3 path) — governance / post-deploy:
UniV3Swapper_v1(uniV3Swapper).setPath(
    fromToken,
    toToken,
    abi.encodePacked(fromToken, uint24(500), toToken)  // example: 0.05% tier
);
```

Until Layer 1 is set, `getRoutesFrom` / `getRoute` return the executor but
`UniV3Swapper.swap` reverts with `NoPathConfigured`.

### Consumer wiring pattern

The Harbor Yield consumer repo overrides a virtual `_configureSwapRoutes` hook. Typical
structure:

```solidity
function _configureSwapRoutes(ConfigPeg peg, Config_MinterMarket[] memory markets) internal {
    address swapper = _predictAddress("swapper");
    address uniV3 = _predictAddress("uniV3Swapper");
    address fxSaveWstEth = _predictAddress("fxSaveWstEthSwapper"); // ETH hyETH
    address curve = _predictAddress("curveSwapper");      // if deployed
    address balancer = _predictAddress("balancerSwapper"); // if deployed

    for (uint256 i = 0; i < markets.length; i++) {
        address wCol = IMinter(_predictAddress(_key(..., "minter"))).WRAPPED_COLLATERAL_TOKEN();
        _wireFxSaveToWstETH(swapper, fxSaveWstEth, wCol);
        // _wireWstETHToStETH(swapper, curve, ...);
        // _wireStETHToWstETH(swapper, balancer, ...);
    }
}
```

Keep executor wiring in private helpers so fork tests in the consumer repo can override
individual routes.

---

## 5. Aggregator wiring (consumer repo, post-deploy)

The aggregator **does not** register in `Swapper_v1`, and it is **not stored on HY**. The Harbor Yield
consumer reaches it only through `HarborYield_v1.redistribute`, which takes the adapter address and the
keeper's `routerData` as call parameters.

```solidity
// 1. Deploy primary aggregator (once per network, shared across pegs) — harbor-swap:
deployVeloraSwapper(state);
address velora = _predictAddress("veloraSwapper");

// Optional: deploy 1inch as a secondary adapter when needed:
// deployOneInchSwapper(state);
// address oneInch = _predictAddress("oneInchSwapper");

// 2. Grant keeper role (per HY peg instance) — consumer repo:
HarborYield_v1(hy).grantRoles(keeperAddress, HarborYield_v1(hy).REDISTRIBUTOR_ROLE());
```

There is no `setAggregatorSwapper` step — HY holds no aggregator address. The keeper passes whichever
adapter it used to build `routerData` (default: `velora`; optional: `oneInch`) on each `redistribute` call, so multiple
third-party adapters can coexist without any HY change.

**Authorization model (intentional tradeoff):** aggregator `swap` is open-access — it only spends
`msg.sender`'s pre-approved balance. The role gate (`REDISTRIBUTOR_ROLE`) lives on `HarborYield_v1.redistribute`,
not on the adapter.

**Keeper call:** the keeper names the tokens, the adapter, and the route on a single `redistribute` call:

```solidity
HarborYield_v1(hy).redistribute(
    fromVault, fromToken, toVault, toToken,
    shares,
    minToAssets,
    velora,        // or oneInch — must match how routerData was built
    routerData
);
```

**Velora `routerData`:** Market API (`GET /prices` → `POST /transactions/:chainId`). Allowlist:
`VeloraV62Selectors.SWAP_EXACT_AMOUNT_IN` (`0xe3ead59e`) or `SWAP_EXACT_AMOUNT_OUT` (`0x7f457675`).
Router: `0x6A000F…1068` ([`VeloraV62Selectors.sol`](../src/swap/aggregator/VeloraV62Selectors.sol)).

**1inch `routerData`:** Swap API / Pathfinder (requires dev-portal KYC). Allowlist:
`OneInchV6Selectors.SWAP` (`0x07ed2379`). Router: `0x1111…2A65`
([`OneInchV6Selectors.sol`](../src/swap/aggregator/OneInchV6Selectors.sol)).

Shared requirements:

- HY sources the swap input by unwinding `shares` of `fromVault` down to `fromToken` inside the call — it needs
  no idle balance.
- `routerData` must target the immutable router baked into the named adapter. Building calldata is off-chain.
- Slippage is bounded by `redistribute`'s end-to-end value floor (`minToAssets` plus the vault's `swapSlippage`);
  HY passes `minAmountOut = 0` to the adapter because the floor is the real guard. A malicious or wrong route
  can't drain HY — the atomic call reverts if the landed value misses the floor.
- Disable the aggregator path for a keeper by revoking `REDISTRIBUTOR_ROLE`; there is no on-chain aggregator
  switch to flip.

**Upgrading an adapter:** deploy a new implementation via `Swapper.sol` and UUPS-upgrade the existing proxy.
Because the keeper names the adapter per call, a new adapter at a different address simply becomes another
address the keeper can pass — no HY change.

---

## 6. Simulate new routes

Use this before adding a hy peg-equiv path (or changing venues). Goal: prove the route is liquid
at the intended rebalance size, pick Curve vs Uni (or aggregator), then set `routeCostRatio`.

### When to simulate

| Path type | Typical venue | Simulation goal |
|-----------|---------------|-----------------|
| **Distribute** (urgent, fixed) | Direct / composite executor | Worst-case fill at keeper size vs oracle fair |
| **Redistribute** (scheduled) | Velora / 1inch | Prefer aggregator unless a dedicated path is clearly better |

### Measure scripts (routeCostRatio)

Re-derive fees + size impact from live mainnet and print constants for
[`ConfigSwap_ETH_mainnet.sol`](src/config/ConfigSwap_ETH_mainnet.sol):

```bash
MAINNET_RPC_URL=https://... yarn measure:route-cost:eth   # fxSAVE ↔ wstETH
MAINNET_RPC_URL=https://... yarn measure:route-cost:btc   # fxSAVE/wstETH → WBTC/LBTC
MAINNET_RPC_URL=https://... yarn measure:route-cost:eur   # fxSAVE/wstETH → EURC
yarn measure:route-cost:usd                               # stub until a USD composite exists
yarn measure:route-cost                                   # alias → eth (back-compat)
```

Optional pinned block: `yarn measure:route-cost:eth 25682862`. Scripts read addresses from the
route config libraries under `src/swap/config/`. Needs `cast` + `python3`.

### Checklist

1. **Identify legs** — tokens, pools/fee tiers, coin indices or Uni path bytes.
2. **Check depth** — Curve `balances(i)`; Uni factory `getPool` + token balances / liquidity.
3. **Quote at size** — intended notional (e.g. 15k fxSAVE, 10 wstETH) via `get_dy` / Uni Quoter.
4. **Quote at epsilon** — same route at ~1 token; scale to size → **size impact** alone.
5. **Fair USD** — Chainlink (or vault/oracle) for input and output; report loss vs fair and vs book TVL.
6. **Reject thin venues** — if one hop dominates loss (e.g. empty wrap pool), switch venue before coding.
7. **Set `routeCostRatio`** — fee + expected slippage via measure scripts → config constants.
8. **Ship** — config library + executor (or Uni `setPath`), fork pool-existence test, `yarn sizes`.

### Quote patterns (`MAINNET_RPC_URL` / `foundry.toml` `mainnet`)

Requires `cast` and a working mainnet RPC. Strip scientific-notation suffixes with `awk '{print $1}'`.
Addresses below match the route configs; prefer reading them from those files when scripting.

**Quoter / factory (mainnet):**

```text
QUOTER_V1      = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6
UNIV3_FACTORY  = 0x1F98431c8aD98523631AE4a59f267346ea31F984
```

**fxSAVE → wstETH (current composite — Curve stables then Uni ETH hop):**

```bash
# 1) fxSAVE → scrvUSD shares
cast call $POOL_FXSAVE_SCRVUSD "get_dy(int128,int128,uint256)(uint256)" 0 1 $AMOUNT_FXSAVE --rpc-url mainnet

# 2) shares → crvUSD
cast call $SCRVUSD_VAULT "previewRedeem(uint256)(uint256)" $SHARES --rpc-url mainnet

# 3) crvUSD → USDC (StableSwap: i=1 crvUSD, j=0 USDC)
cast call $POOL_CRVUSD_USDC "get_dy(int128,int128,uint256)(uint256)" 1 0 $CRVUSD --rpc-url mainnet

# 4) USDC → WETH (0.05%) → wstETH (0.01%) — path from ConfigFxSaveWstEthRoute.uniPathUsdcToWstEth()
cast call $QUOTER_V1 "quoteExactInput(bytes,uint256)(uint256)" $PATH_USDC_TO_WSTETH $USDC_OUT --rpc-url mainnet
```

**fxSAVE → WBTC (Curve stables + Uni USDC/WBTC 0.05%):**

```bash
# 1–2) same as fxSAVE → wstETH through crvUSD
cast call $POOL_FXSAVE_SCRVUSD "get_dy(int128,int128,uint256)(uint256)" 0 1 $AMOUNT_FXSAVE --rpc-url mainnet
cast call $SCRVUSD_VAULT "previewRedeem(uint256)(uint256)" $SHARES --rpc-url mainnet
# 3) crvUSD → USDC (StableSwap: i=1 crvUSD, j=0 USDC)
cast call $POOL_CRVUSD_USDC "get_dy(int128,int128,uint256)(uint256)" 1 0 $CRVUSD --rpc-url mainnet
# 4) USDC → WBTC (UniV3 0.05%)
cast call $QUOTER_V1 "quoteExactInputSingle(address,address,uint24,uint256,uint160)(uint256)" \
  $USDC $WBTC 500 $USDC_OUT 0 --rpc-url mainnet
```

**WBTC → LBTC (UniV3 0.01%):**

```bash
cast call $QUOTER_V1 "quoteExactInputSingle(address,address,uint24,uint256,uint160)(uint256)" \
  $WBTC $LBTC 100 $AMOUNT_WBTC 0 --rpc-url mainnet
```

**wstETH → WBTC / LBTC (UniV3 multi-hop via WETH):**

```bash
# path = abi.encodePacked(wstETH, uint24(100), WETH, uint24(500), WBTC)
# optional + uint24(100), LBTC for three-hop
cast call $QUOTER_V1 "quoteExactInput(bytes,uint256)(uint256)" $PATH_BYTES $AMOUNT_WSTETH --rpc-url mainnet
```

**fxSAVE → EURC:**

```bash
# after crvUSD (same as above) → USDC, then:
cast call $QUOTER_V1 "quoteExactInputSingle(address,address,uint24,uint256,uint160)(uint256)" \
  $USDC $EURC 500 $USDC_OUT 0 --rpc-url mainnet
```

Confirm pools exist:

```bash
cast call $UNIV3_FACTORY "getPool(address,address,uint24)(address)" $TOKEN_A $TOKEN_B $FEE --rpc-url mainnet
```

### How to report loss

| Metric | Meaning |
|--------|---------|
| **vs fair** | Output USD ÷ input fair USD − 1 (oracle / spot-scaled epsilon) |
| **size impact** | Actual out ÷ (epsilon out × size/epsilon) − 1 |
| **vs book TVL** | Absolute USD loss ÷ market TVL (e.g. $500k mint) — bps drag on the whole book |
| **hy↔ha rate** | If rate \(R\) scales with NAV: \(R_\text{new} = R \times (1 - L/\text{TVL})\) |

Document the chosen venues in the route config library natspec and the hy peg-equiv table in §3.

### After coding

```bash
forge test --match-contract HyPegEquiv -vv   # unsupported-pair + fork venue checks
forge test --match-contract FxSaveWstEth -vv # unit + fork for the ETH composite
yarn sizes                                   # stage regression/sizes.txt if expected
```

Fork tests should assert on-chain pool/path existence (Curve `coins` / Uni `getPool`), not only compile-time constants.

---

## 7. Mainnet pool caveats

### Curve (`CurveSwapper_v1`)

**Supported:** StableSwap-style pools exposing:

- `exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)`
- `exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)` (lending / meta pools)

**Not supported by this executor:**

- **Crypto pools** (`exchange(uint256 i, uint256 j, ...)`) — different selector and index
  type. Route via aggregator, a composite that uses `CurveExchangeLib` Crypto kind, or add a dedicated executor.
- **NG factory pools** with non-standard ABIs — verify on Etherscan before wiring.
- **Multi-pool routes** (A → B → C across two Curve pools) — use aggregator or a dedicated
  composite executor (e.g. `FxSaveWstEthSwapper_v1`).

**Discovering `i` and `j`:**

1. Read `pool.coins(k)` for `k = 0, 1, …` until you find `fromToken` and `toToken`.
2. Set `useUnderlying = false` when swapping the pool's native coin addresses.
3. Set `useUnderlying = true` when the tradable asset is an underlying (e.g. cDAI in a
   lending meta pool) — confirm with a small fork test before mainnet config.

**Legacy vs modern return type:** Older pools (e.g. 3pool) return `void` from `exchange`;
newer pools return `uint256`. `CurveSwapper_v1` uses balance delta for `amountOut`, so both
work. Verify with a mainnet fork in the consumer repo before wiring.

### Balancer (`BalancerSwapper_v1`)

**Supported:** Balancer **V2** Vault single-swap (`SwapKind.GIVEN_IN` only). One `poolId`
per registered pair.

**Not supported:**

- **Balancer V3** — different Vault address and API. Would need a separate executor when V3
  liquidity is required.
- **`batchSwap` multi-hop** — not implemented. Multi-hop Balancer routes → aggregator.

**Discovering `poolId`:**

- Balancer app pool page, or
- `IVault(0xBA12…2C8).getPool(poolAddress)` on mainnet.

**Token ordering:** `assetIn` / `assetOut` are taken from the swap arguments at runtime;
only `poolId` is stored. Ensure the pool actually contains both tokens.

### Uniswap v3 (`UniV3Swapper_v1`)

- Multi-hop supported via longer `path` bytes.
- Fee tiers must match live pools (`100`, `500`, `3000`, `10000`, etc.).
- Mainnet router: `0xE592427A0AEce92De3Edee1F18E0157C05861564` (SwapRouter, not SwapRouter02 —
  confirm against the router your pools were deployed against).
- For quotes, Uni Quoter V1 (`0xb273…AB6`) is enough; QuoterV2 may be absent on some RPCs.

---

## 8. Roles and governance

| Contract | Role constant | Who needs it |
|----------|---------------|--------------|
| `Swapper_v1` | `ROUTE_SETTER_ROLE` | Ops configuring registry entries without full owner |
| `UniV3Swapper_v1` | `PATH_SETTER_ROLE` | Ops setting encoded paths |
| `CurveSwapper_v1` | `ROUTE_SETTER_ROLE` | Ops setting pool + indices |
| `BalancerSwapper_v1` | `ROUTE_SETTER_ROLE` | Ops setting poolId |
| `HarborYield_v1` | `REDISTRIBUTOR_ROLE` | Keeper / bot calling `redistribute` (consumer repo) |

Owner on each contract can always perform setters and upgrades (UUPS). After deployment,
ownership transfers to the Safe — route changes become Safe transactions (or role grants to
an ops multisig).

**Security reminders:**

- `REDISTRIBUTOR_ROLE` is high-trust, but `redistribute`'s atomic end-to-end value floor bounds any loss to the
  vault's `swapSlippage`: a compromised keeper cannot drain HY — a route that fails to deliver reverts the call.
- Compromise of `ROUTE_SETTER_ROLE` on `Swapper_v1` redirects pairs to a malicious executor
  — executors only act on tokens HY explicitly approves per swap, but still treat as critical.
- Curve pool addresses come from governance storage; verify pool contract on Etherscan before
  `setRoute`.

---

## 9. Verification checklist

**Unit + executor fork tests (this repo):**

```bash
forge build
forge test --match-path "test/swap/**" --no-match-path "test/swap/fork/**" -vv
# Pinned mainnet forks (require MAINNET_RPC_URL):
forge test --match-path "test/swap/fork/**" --fork-url "$MAINNET_RPC_URL" -vv
```

**Full-stack HY integration:** run in the Harbor Yield consumer repo (HY + ACs + oracles +
swap registry wiring). Not included in harbor-swap.

On-chain reads after deploy (replace addresses):

```solidity
// Registry (single pair or legacy storage reads)
ISwapper.RouteInfo memory info = Swapper_v1(swapper).getRoute(from, to);
Swapper_v1(swapper).swapExecutors(from, to);
Swapper_v1(swapper).routeCostRatios(from, to);

// Config events (index from block logs after setRoute / setPath)
// Swapper_v1:     RouteUpdated(from, to, executor, routeCostRatio)
// UniV3Swapper:   PathSet(from, to, path)
// Curve/Balancer: RouteSet(...)
// VeloraSwapper / OneInchSwapper: AggregatorSwap(...) on each swap

// Executors
UniV3Swapper_v1(uniV3).paths(from, to).length > 0;
CurveSwapper_v1(curve).routes(from, to).pool != address(0);
BalancerSwapper_v1(bal).poolIds(from, to) != bytes32(0);
// Hy peg-equiv venues: test/swap/fork/HyPegEquivRouteConfigFork.t.sol
// Hy peg-equiv E2E:     test/swap/fork/HyPegEquivSwapFork.t.sol
// FxSaveWstEthSwapper: also covered by test/swap/fork/FxSaveWstEthSwapperFork.t.sol

// Aggregator (consumer repo)
HarborYield_v1(hy).hasAnyRole(keeper, HarborYield_v1(hy).REDISTRIBUTOR_ROLE());
VeloraSwapper_v1(velora).ROUTER() == 0x6A000F20005980200259B80c5102003040001068;
OneInchSwapper_v1(oneInch).ROUTER() == 0x111111125421cA6dc452d289314280a0f8842A65;
```

Dry-run a direct swap: fund the executor's caller (HY during `distribute`, or the executor
proxy in isolation in tests), ensure `minAmountOut` respects HY's oracle floor.

---

## 10. Related files

| File / repo | Role |
|-------------|------|
| [baofinance/harbor-swap](https://github.com/baofinance/harbor-swap) | This repo — swap contracts, deploy scripts, unit tests |
| [baofinance/harbor](https://github.com/baofinance/harbor) | Phase 1a — Minter, SP, SPM; `HarborDeployer`, BaoFactory |
| [baofinance/harbor-price-aggregators](https://github.com/baofinance/harbor-price-aggregators) | Phase 1b — oracles via BaoFactory |
| [`script/src/contracts/Swapper.sol`](src/contracts/Swapper.sol) | BaoFactory deploy for all swap proxies |
| [`script/src/HarborSwapDeployStack.sol`](src/HarborSwapDeployStack.sol) | `SwapDeployOptions`, `deploySwapStack` |
| [`script/src/Deploy_Swap.sol`](src/Deploy_Swap.sol) | Standalone full swap stack deploy |
| [`script/Deploy_Swap.s.sol`](../Deploy_Swap.s.sol) | Runnable forge script for swap-only deploy |
| [`script/measure-route-cost-eth.sh`](measure-route-cost-eth.sh) | Live fxSAVE ↔ wstETH routeCostRatio |
| [`script/measure-route-cost-btc.sh`](measure-route-cost-btc.sh) | Live hyBTC routeCostRatio |
| [`script/measure-route-cost-eur.sh`](measure-route-cost-eur.sh) | Live hyEUR routeCostRatio |
| [`script/measure-route-cost-usd.sh`](measure-route-cost-usd.sh) | USD stub (until a dedicated route exists) |
| [`src/swap/README.md`](../src/swap/README.md) | Architecture + threat model |
| [`src/swap/config/`](../src/swap/config/) | Per-route mainnet venue constants |
