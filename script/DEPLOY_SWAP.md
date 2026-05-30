# Swap deploy and route-configuration runbook

Operational guide for deploying the Harbor swap stack and wiring routes on mainnet (or
fork tests). For architecture, threat model, and interface contracts see
[`src/swap/README.md`](../src/swap/README.md). For HY accounting context see
[`doc/design.md`](../doc/design.md) §6.20 and §9 (deployment phases).

**Production rule:** all swap **proxies** deploy through [**BaoFactory**](https://github.com/baofinance/harbor)
CREATE3 via the harbor-yield deploy scripts — never hand-roll `new Swapper_v1` + ERC1967Proxy
for mainnet. Implementation contracts are deployed with `new` in-script; UUPS proxies are
always factory-deployed at deterministic salts.

---

## 0. Prerequisites — BaoFactory CREATE3 and cross-repo deploy

Swap deployment is **Phase 2** of the Harbor stack. It assumes Phase 1 is already live.

### Cross-repo ordering

| Phase | Repo | Delivers (swap-relevant) |
|-------|------|--------------------------|
| **1a** | [baofinance/harbor](https://github.com/baofinance/harbor) | `Minter_v3`, `StabilityPool_v3`, `StabilityPoolManager_v2` — AC compound + `distribute()` source |
| **1b** | [baofinance/harbor-price-aggregators](https://github.com/baofinance/harbor-price-aggregators) | `IWrappedPriceOracle` impls at CREATE3 addresses (e.g. `EthPriceAggregator_ETH_mainnet`, `Aggregator_stETH_ETH_mainnet` for wstETH equiv vault) |
| **2** | harbor-yield (this repo) | `Swapper_v1`, executors, aggregator adapter, `HarborYield_v1`, ACs, equiv adapters |

Phase 1a and 1b are independent of each other; **both must complete before Phase 2**.

Oracle addresses from harbor-price-aggregators are predictable from the same salt scheme
BaoFactory uses. Example (ETH peg): wstETH equivalent vault reads
`Aggregator_stETH_ETH_mainnet` deployed by harbor-price-aggregators — see
[`Deploy_ETH_HarborYield._deployWstETHOracle`](src/Deploy_ETH_HarborYield.sol). Fork tests
mock oracles at `_predictAddress(...)` when the price-aggregators repo has not been run
(see [`DeployETHSetUp.t.sol`](../test/deployment/DeployETHSetUp.t.sol)).

### How BaoFactory deployment works

All harbor-yield deploy scripts inherit [`HarborDeployer`](https://github.com/baofinance/harbor)
(from `lib/harbor/script/` via `@harbor-script/`). Swap proxies use:

```solidity
// script/src/contracts/Swapper.sol — every executor + registry
proxy = _deployProxyAndRecord(stateData, "uniV3Swapper", impl, initData);
```

`_deployProxyAndRecord` (in `HarborFactoryDeployer` / `HarborDeployer`) calls
`IBaoFactory(baoFactory()).deploy(...)` with a CREATE3 salt derived from
`_saltString(key)`. The resulting address is **deterministic** from `{saltPrefix}::{key}`.

Special case — entry beacon (not a UUPS proxy):

```solidity
// script/src/contracts/HarborYield.sol
IBaoFactory(baoFactory()).deploy(
    abi.encodePacked(type(HarborYieldEntryBeacon_v1).creationCode, abi.encode(entryImpl, owner())),
    keccak256(abi.encodePacked(_saltString(beaconKey)))
);
```

**Address prediction before deploy:**

```solidity
_setSaltPrefix("harbor_v1::eth");
address swapper = _predictAddress("swapper");       // valid before deploySwapper runs
address uniV3   = _predictAddress("uniV3Swapper");
```

This is how [`HarborYield_v1`](../../src/HarborYield_v1.sol) receives `SWAPPER` as an
immutable at construction time and how AC impls bake in `YIELD_MANAGER = _predictAddress(hyKey)`.

### Operator and ownership

1. Deploy script runner must be a **BaoFactory operator** for the duration of the script:
   ```solidity
   vm.prank(IBaoFactory(factory).owner());
   IBaoFactory(factory).setOperator(deployScript, expiry);
   ```
   Production: Safe or ops key granted operator by factory owner before running the script.

2. Proxies initialize with `(deployerOwner, pendingOwner)` — deploy script is temporary
   owner, then `_transferAllOwnerships()` hands control to the Safe.

3. Route wiring (`setRoute`, `setPath`, `setAggregatorSwapper`) runs **while the deploy
   script still owns** the contracts, inside `_configureSwapRoutes` or immediately after
   deploy, before ownership transfer.

### Salt keys (swap stack)

Full salt = `{saltPrefix}::{key}`. Swap contracts use **peg-agnostic** keys (shared across
HY peg instances on the same network):

| Key | Proxy via `_deployProxyAndRecord` |
|-----|-----------------------------------|
| `swapper` | `Swapper_v1` registry |
| `uniV3Swapper` | `UniV3Swapper_v1` |
| `curveSwapper` | `CurveSwapper_v1` |
| `balancerSwapper` | `BalancerSwapper_v1` |
| `oneInchSwapper` | `OneInchSwapper_v1` |
| `fxSaveWstEthSwapper` | `FxSaveWstEthSwapper_v1` (ETH mainnet fxSAVE → wstETH composite) |

Per-peg HY uses `{pegKey}::harborYield`, `{pegKey}::beacon`, etc. — see
[`HarborYieldDeployer`](src/HarborYieldDeployer.sol).

### What not to do on mainnet

- Do **not** deploy swap proxies outside `Swapper.sol` / `HarborYieldDeployer` helpers.
- Do **not** hard-code proxy addresses in source — use `_predictAddress` + config mixins.
- Do **not** wire registry routes to an EOA or unverified contract — only CREATE3 executor
  proxies registered via `ISwapperConfig.setRoute`.
- Do **not** skip harbor-price-aggregators oracles for equiv vaults that reference them in
  deploy config — registration will revert on peg-drift checks or valuation will be wrong.

### Tests mirror production

[`BaoTest._ensureBaoFactory()`](../lib/harbor/lib/bao-base/test/) bootstraps Nick's Factory →
BaoFactory proxy → v1 upgrade. Swap unit tests (`test/swap/...`) and fork setup
(`DeployETHSetUp`) call the same `deploySwapper` / `deployUniV3Swapper` paths as production.
Override `deploySwapperImplementation()` to inject `MockSwapper` without bypassing CREATE3.

---

## 1. Which path to use

| Scenario | Path | Entrypoint | When |
|----------|------|------------|------|
| **Urgent / peg-critical** | Direct executor | `HarborYield_v1.distribute()` → `ISwapExecutor.swap` | Residual wCOLn routing during AC distribution; must be predictable gas, no off-chain router dependency |
| **Low-urgency / long-tail** | Aggregator (1inch v6) | `HarborYield_v1.executeAggregatorSwap` | Scheduled rebalances, illiquid pairs, multi-pool Curve/Balancer chains, exotic venues |

**Rule:** `distribute()` never calls the aggregator. Untrusted keeper calldata stays out of
the hot path. After an aggregator swap, output tokens sit in HY's idle balance until the
next `distribute()` deposits them into the appropriate managed vault.

---

## 2. Contract inventory

All swap proxies share the deploy script salt prefix (e.g. `harbor_v1::eth::`) and are
**peg-agnostic** — one set per network, shared across HY peg instances on that network.

| Salt key | Contract | Purpose |
|----------|----------|---------|
| `swapper` | `Swapper_v1` | Route registry: `(from, to) → {executor, feeRatio}` |
| `uniV3Swapper` | `UniV3Swapper_v1` | Uniswap v3 `exactInput` (single- or multi-hop) |
| `curveSwapper` | `CurveSwapper_v1` | Curve StableSwap `exchange` / `exchange_underlying` |
| `balancerSwapper` | `BalancerSwapper_v1` | Balancer V2 Vault single-swap |
| `oneInchSwapper` | `OneInchSwapper_v1` | 1inch v6 fixed-router adapter (aggregator only) |
| `fxSaveWstEthSwapper` | `FxSaveWstEthSwapper_v1` | fxSAVE → wstETH composite (Curve ×2 + scrvUSD redeem; ETH mainnet) |

Deploy helpers live in [`script/src/contracts/Swapper.sol`](src/contracts/Swapper.sol).

Chain constants:

| Constant | Address | File |
|----------|---------|------|
| Uniswap v3 SwapRouter (mainnet) | `0xE592427A0AEce92De3Edee1F18E0157C05861564` | e.g. [`ConfigHarborYield_ETH_wstETH.sol`](src/config/ConfigHarborYield_ETH_wstETH.sol) |
| Balancer V2 Vault (all major chains) | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` | [`ConfigBalancer.sol`](src/config/ConfigBalancer.sol) |
| 1inch AggregationRouterV6 (CREATE2, all major chains) | `0x111111125421cA6dc452d289314280a0f8842A65` | [`ConfigOneInch.sol`](src/config/ConfigOneInch.sol) |

Curve has **no canonical router** — each pair points at a specific pool contract.

---

## 3. Deploy order (Phase 2 — via BaoFactory)

Swap deployment is orchestrated by [`DeploySwapStack`](src/DeploySwapStack.sol) (`deploySwapStack`).
Two entrypoints:

| Script | When | What it deploys |
|--------|------|-----------------|
| [`Deploy_Swap.s.sol`](../Deploy_Swap.s.sol) | Swap stack only, shared infra before any HY peg | Registry + UniV3 + Curve + Balancer + 1inch |
| [`Deploy_ETH_HarborYield.s.sol`](../Deploy_ETH_HarborYield.s.sol) `run` | Default ETH HY deploy | Registry + UniV3, then HY stack |
| [`Deploy_ETH_HarborYield.s.sol`](../Deploy_ETH_HarborYield.s.sol) `runFull` | ETH HY with full swap + aggregator wiring | Registry + all executors + 1inch + HY + `setAggregatorSwapper` |

**Standalone swap stack** (no HarborYield):

```bash
script/run-script Deploy_Swap --salt harbor_v1 --network mainnet
```

**ETH HarborYield with full swap stack**:

```bash
script/run-script Deploy_ETH_HarborYield runFull --salt harbor_v1 --network mainnet
```

Within harbor-yield, peg deploy is invoked from
[`Deploy_ETH_HarborYield.deployETHHarborYield`](src/Deploy_ETH_HarborYield.sol). That
function builds a `DeploymentTypes.State` with `baoFactory: baoFactory()` and runs:

```
Prerequisites (Phase 1a + 1b — other repos, must be done first)
  harbor:          Minter_v3, SP_v3, SPM_v2 live
  price-aggregators: oracles at predicted CREATE3 addresses (e.g. Aggregator_stETH_ETH_mainnet)

Phase 2 — harbor-yield deploy script (BaoFactory operator)
  1. _setSaltPrefix(saltPrefix)
  2. deploySwapStack(state, opts)       → swapper + uniV3 [+ curve + balancer + oneInch]
  3. deployHarborYieldForPeg(...)      → ACs, equiv vaults, HY proxy (also all CREATE3)
  4. _configureSwapRoutes(peg, markets) → two-layer route wiring (see §4)
  5. [when deployOneInch] setAggregatorSwapper on HY (+ optional AGGREGATOR_ROLE)
  6. flush + _transferAllOwnerships()  → Safe receives proxy ownership
```

`Deploy_Swap` runs steps 1–2 + 6 only (no HarborYield). Steps 2 optional executors are
controlled by `SwapDeployOptions` (`deployCurve`, `deployBalancer`, `deployOneInch`).
Default `run` uses registry + UniV3 only; `runFull` / `Deploy_Swap` use all three flags.

**Immutables wired at deploy time:** `HarborYield_v1` constructor takes
`swapper = _predictAddress("swapper")` (passed from deploy script). Executor routers/Vaults
are constructor args on impl deployment (`UniV3Swapper_v1(router)`,
`BalancerSwapper_v1(BALANCER_V2_VAULT)`); the **proxy** address is what gets registered in
`Swapper_v1`.

**Important:** `_configureSwapRoutes` runs while the deploy script still owns the contracts.
Route setters require owner (or delegated `*_SETTER_ROLE`).

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
ISwapperConfig(swapper).setRoute(fromToken, toToken, executorProxy, feeRatio);
```

- `executorProxy` = CREATE3 address of the executor (e.g. `_predictAddress("uniV3Swapper")`).
- `feeRatio` = effective swap fee as 1e18-scaled ratio (e.g. `3e15` = 0.3%). HY reads this
  in `distribute()` as the minting threshold — set it **≥** the real pool fee so residual
  swaps only run when economically sensible.
- Pass `executor = address(0)` to remove a registry entry.

### Example — ETH peg fxSAVE → wstETH (FxSaveWstEthSwapper)

Production ETH wiring uses a **dedicated composite executor** (not UniV3). From
[`Deploy_ETH_HarborYield`](src/Deploy_ETH_HarborYield.sol):

```solidity
// Deploy (once per network, shared across pegs):
deployFxSaveWstEthSwapper(state);
address fxSaveWstEth = _predictAddress("fxSaveWstEthSwapper");

// Layer 2 (registry) — in _configureSwapRoute:
ISwapperConfig(swapper).setRoute(wrappedCollateral, WSTETH, fxSaveWstEth, FXSAVE_TO_WSTETH_FEE_RATIO);
```

**No Layer 1 config** — venues and coin indices are compiled into
[`ConfigFxSaveWstEthRoute_ETH_mainnet`](../src/swap/config/ConfigFxSaveWstEthRoute_ETH_mainnet.sol)
and baked into the implementation. Route changes require a new implementation + UUPS upgrade
(or a new dedicated executor proxy).

**Slippage note:** intermediate Curve legs use `min_dy = 0`; only final wstETH output is
bounded by HarborYield's oracle floor (`minAmountOut`). Monitor pool liquidity for large
residual fxSAVE during `distribute()` Phase 3.

### Example — generic UniV3 pair (Layer 1 + Layer 2)

For pairs wired through `UniV3Swapper_v1`:

```solidity
// Layer 2 (registry):
ISwapperConfig(swapper).setRoute(fromToken, toToken, uniV3Swapper, feeRatio);

// Layer 1 (UniV3 path) — governance / post-deploy:
UniV3Swapper_v1(uniV3Swapper).setPath(
    fromToken,
    toToken,
    abi.encodePacked(fromToken, uint24(500), toToken)  // example: 0.05% tier
);
```

Until Layer 1 is set, `getRoutesFrom` / `getRoute` return the executor but
`UniV3Swapper.swap` reverts with `NoPathConfigured`.

### Virtual hook pattern

Peg-specific deployers override `HarborYieldDeployer._configureSwapRoutes`:

```solidity
function _configureSwapRoutes(ConfigPeg peg, Config_MinterMarket[] memory markets) internal override {
    address swapper = _predictAddress("swapper");
    address uniV3 = _predictAddress("uniV3Swapper");
    address fxSaveWstEth = _predictAddress("fxSaveWstEthSwapper"); // ETH hyETH
    address curve = _predictAddress("curveSwapper");      // if deployed
    address balancer = _predictAddress("balancerSwapper"); // if deployed

    for (uint256 i = 0; i < markets.length; i++) {
        address wCol = IMinter(_predictAddress(_key(..., "minter"))).WRAPPED_COLLATERAL_TOKEN();
        _wireFxSaveToWstETH(swapper, fxSaveWstEth, wCol);
        // _wireWstETHToStETH(swapper, curve, curve, ...);
        // _wireStETHToWstETH(swapper, balancer, balancer, ...);
    }
}
```

Keep executor wiring in private helpers so fork tests can override individual routes via
`_configureSwapRoute` (see `DeployETHSetUp.t.sol`).

---

## 5. Aggregator wiring (post-deploy)

The aggregator **does not** register in `Swapper_v1`. It connects directly to each HY
instance.

```solidity
// 1. Deploy adapter (once per network, shared across pegs)
deployOneInchSwapper(state);
address oneInch = _predictAddress("oneInchSwapper");

// 2. Point HY at the adapter (per HY peg instance)
IHarborYield(hy).setAggregatorSwapper(oneInch);

// 3. Grant keeper role (per HY)
HarborYield_v1(hy).grantRoles(keeperAddress, HarborYield_v1(hy).AGGREGATOR_ROLE());
```

**Keeper call:**

```solidity
HarborYield_v1(hy).executeAggregatorSwap(
    fromToken,
    toToken,
    amountIn,
    minAmountOut,
    routerData   // opaque 1inch v6 calldata from off-chain pathfinder
);
```

Requirements:

- HY must hold `amountIn` of `fromToken` as idle balance (not locked in a vault).
- `routerData` must target the immutable router baked into `OneInchSwapper_v1` (`0x1111…2A65`
  on production). Building calldata is an off-chain concern (1inch API, Pathfinder, etc.).
- Set `minAmountOut` conservatively; slippage is enforced both inside 1inch calldata and by
  the adapter's balance-delta check.
- Disable aggregator: `setAggregatorSwapper(address(0))`.

---

## 6. Mainnet pool caveats

### Curve (`CurveSwapper_v1`)

**Supported:** StableSwap-style pools exposing:

- `exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)`
- `exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy)` (lending / meta pools)

**Not supported by this executor:**

- **Crypto pools** (`exchange(uint256 i, uint256 j, ...)`) — different selector and index
  type. Route via aggregator or add a dedicated `CurveCryptoSwapper_v1`.
- **NG factory pools** with non-standard ABIs — verify on Etherscan before wiring.
- **Multi-pool routes** (A → B → C across two Curve pools) — use aggregator or chain two
  registry entries with an intermediate token (two separate swaps).

**Discovering `i` and `j`:**

1. Read `pool.coins(k)` for `k = 0, 1, …` until you find `fromToken` and `toToken`.
2. Set `useUnderlying = false` when swapping the pool's native coin addresses.
3. Set `useUnderlying = true` when the tradable asset is an underlying (e.g. cDAI in a
   lending meta pool) — confirm with a small fork test before mainnet config.

**Legacy vs modern return type:** Older pools (e.g. 3pool) return `void` from `exchange`;
newer pools return `uint256`. `CurveSwapper_v1` uses balance delta for `amountOut`, so both
work. Always verify with `forge test` on a mainnet fork.

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
- Fee tiers must match live pools (`500`, `3000`, `10000`, etc.).
- Mainnet router: `0xE592427A0AEce92De3Edee1F18E0157C05861564` (SwapRouter, not SwapRouter02 —
  confirm against the router your pools were deployed against).

---

## 7. Roles and governance

| Contract | Role constant | Who needs it |
|----------|---------------|--------------|
| `Swapper_v1` | `ROUTE_SETTER_ROLE` | Ops configuring registry entries without full owner |
| `UniV3Swapper_v1` | `PATH_SETTER_ROLE` | Ops setting encoded paths |
| `CurveSwapper_v1` | `ROUTE_SETTER_ROLE` | Ops setting pool + indices |
| `BalancerSwapper_v1` | `ROUTE_SETTER_ROLE` | Ops setting poolId |
| `HarborYield_v1` | `AGGREGATOR_ROLE` | Keeper / bot calling `executeAggregatorSwap` |

Owner on each contract can always perform setters and upgrades (UUPS). After deployment,
ownership transfers to the Safe — route changes become Safe transactions (or role grants to
an ops multisig).

**Security reminders:**

- Never grant `AGGREGATOR_ROLE` to an EOA that builds its own 1inch calldata without review;
  compromised calldata can drain HY's approved balance for that transaction.
- Compromise of `ROUTE_SETTER_ROLE` on `Swapper_v1` redirects pairs to a malicious executor
  — executors only act on tokens HY explicitly approves per swap, but still treat as critical.
- Curve pool addresses come from governance storage; verify pool contract on Etherscan before
  `setRoute`.

---

## 8. Verification checklist

After wiring routes on a fork (`MAINNET_RPC_URL` in `.env`):

```bash
set -a && source .env && set +a
forge test --mc DeployETHSetUpTest -vv   # full ETH stack + swap registry
forge test --mc 'UniV3SwapperTest|CurveSwapperTest|BalancerSwapperTest|OneInchSwapperTest' -vv
forge test --mc HarborYieldTest --mt aggregator -vv
```

On-chain reads (replace addresses):

```solidity
// Registry (single pair or legacy storage reads)
ISwapper.RouteInfo memory info = Swapper_v1(swapper).getRoute(from, to);
Swapper_v1(swapper).swapExecutors(from, to);
Swapper_v1(swapper).swapFeeRatios(from, to);

// Config events (index from block logs after setRoute / setPath)
// Swapper_v1:     RouteUpdated(from, to, executor, feeRatio)
// UniV3Swapper:   PathSet(from, to, path)
// Curve/Balancer: RouteSet(...)
// OneInchSwapper: AggregatorSwap(...) on each swap

// Executors
UniV3Swapper_v1(uniV3).paths(from, to).length > 0;
CurveSwapper_v1(curve).routes(from, to).pool != address(0);
BalancerSwapper_v1(bal).poolIds(from, to) != bytes32(0);
FxSaveWstEthSwapper_v1(fxSaveWstEth).swap(FXSAVE, WSTETH, ...); // fork test only

// Aggregator
HarborYield_v1(hy).aggregatorSwapper() == oneInchProxy;
HarborYield_v1(hy).hasAnyRole(keeper, AGGREGATOR_ROLE);
OneInchSwapper_v1(oneInch).ROUTER() == 0x111111125421cA6dc452d289314280a0f8842A65;
```

Dry-run a direct swap: fund the executor's caller (HY during `distribute`, or the executor
proxy in isolation in tests), ensure `minAmountOut` respects HY's oracle floor (see
`doc/design.md` §6.20).

---

## 9. Future repo extraction (Phase 3)

The swap subtree under `src/swap/` is split-ready. Extraction to standalone
`harbor-swapadapter` is **deferred** until:

1. A second Harbor product imports `@harbor-swap/...`, or
2. Audit/compliance requires a separately-versioned artifact, or
3. The swap subtree dominates review scope.

Mechanical recipe: [`src/swap/README.md`](../src/swap/README.md) § "When this becomes its
own repo".

---

## 10. Related files and repos

| File / repo | Role |
|-------------|------|
| [baofinance/harbor](https://github.com/baofinance/harbor) | Phase 1a — Minter, SP, SPM; provides `HarborDeployer`, BaoFactory, `@harbor-script/` |
| [baofinance/harbor-price-aggregators](https://github.com/baofinance/harbor-price-aggregators) | Phase 1b — oracles (`Aggregator_stETH_ETH_mainnet`, etc.) via BaoFactory; see `script/README.md` there |
| [`script/src/contracts/Swapper.sol`](src/contracts/Swapper.sol) | BaoFactory deploy for all swap proxies (incl. `deployFxSaveWstEthSwapper`) |
| [`script/src/HarborYieldDeployer.sol`](src/HarborYieldDeployer.sol) | `_configureSwapRoutes` hook; `deployHarborYieldForPeg` |
| [`script/src/DeploySwapStack.sol`](src/DeploySwapStack.sol) | `SwapDeployOptions`, `deploySwapStack` |
| [`script/src/Deploy_Swap.sol`](src/Deploy_Swap.sol) | Standalone full swap stack deploy |
| [`script/Deploy_Swap.s.sol`](../Deploy_Swap.s.sol) | Runnable forge script for swap-only deploy |
| [`script/Deploy_ETH_HarborYield.s.sol`](../Deploy_ETH_HarborYield.s.sol) | Runnable forge script (`run` / `runFull`) |
| [`script/src/Deploy_ETH_HarborYield.sol`](src/Deploy_ETH_HarborYield.sol) | ETH peg reference deploy |
| [`doc/design.md`](../doc/design.md) §9 | Full cross-repo phase diagram |
| [`src/swap/README.md`](../src/swap/README.md) | Architecture + threat model |
| [`test/deployment/DeployETHSetUp.t.sol`](../test/deployment/DeployETHSetUp.t.sol) | Fork integration test (BaoFactory + mocked oracles) |
