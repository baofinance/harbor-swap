# harbor-swap

Harbor swap registry (`Swapper_v1`), direct DEX executors (UniV3, Curve, Balancer, composite
routes), and aggregator adapters (Velora Augustus v6.2 primary; 1inch v6 optional). Deployed via BaoFactory CREATE3; consumed by
Harbor Yield and other Harbor products.

## Docs

- Architecture and threat model: [`src/swap/README.md`](src/swap/README.md)
- Deploy runbook: [`script/DEPLOY_SWAP.md`](script/DEPLOY_SWAP.md)
- Executor hardening divergence: [`doc/swap-executor-divergence.md`](doc/swap-executor-divergence.md)

## Build and test

```bash
git submodule update --init --recursive
forge build
forge test --match-path "test/swap/**"
```

**Test scope:** mock-based unit tests under `test/swap/` plus pinned mainnet fork tests under
`test/swap/fork/` (require `MAINNET_RPC_URL`). All executors and aggregator adapters share
`SwapExecutorBase` — notably `amountOut == 0` always reverts (`ZeroAmountOut`), even when
`minAmountOut == 0`.

**Aggregator calldata:** Harbor Option A — per adapter:
- **Velora (primary):** pin `GET /prices` with `version=6.2` and
  `includeContractMethods=swapExactAmountIn,swapExactAmountOut`; allowlisted selectors
  `0xe3ead59e` / `0x7f457675`. Pass `userAddress` = adapter proxy and `txOrigin` = outer sender
  on `POST /transactions`.
- **1inch (optional):** `swap` (`0x07ed2379`) via Swap API / Pathfinder (requires dev-portal KYC)

Keepers pass the adapter address per `redistribute` call. Deploy Velora with `_veloraAggregatorDeployOptions()` or the full stack with `_fullSwapDeployOptions()`.

**Known design tradeoffs** (documented in `src/swap/README.md`):

- `FxSaveWstEthSwapper_v1` intermediate Curve legs use `min_dy = 0`; only final wstETH
  output is bounded by the consumer's `minAmountOut`. Route changes require impl upgrade.
- Aggregator adapters are open-access; authorization lives on the consumer's `redistribute`
  `REDISTRIBUTOR_ROLE` gate. Selector allowlist does not validate swap parameters.

## License

MIT — see [LICENSE](LICENSE).

Third-party: Uniswap v3 periphery (GPL-2.0-or-later) is used by `UniV3Swapper_v1`.
