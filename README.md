# harbor-swap

Harbor swap registry (`Swapper_v1`), direct DEX executors (UniV3, Curve, Balancer, composite
routes), and the 1inch v6 aggregator adapter. Deployed via BaoFactory CREATE3; consumed by
Harbor Yield and other Harbor products.

## Docs

- Architecture and threat model: [`src/swap/README.md`](src/swap/README.md)
- Deploy runbook: [`script/DEPLOY_SWAP.md`](script/DEPLOY_SWAP.md)

## Build and test

```bash
git submodule update --init --recursive
forge build
forge test --match-path "test/swap/**"
```

**Test scope:** mock-based unit tests only (71 tests under `test/swap/`). Mainnet fork
integration (full ETH stack + oracle mocks) lives in the Harbor Yield consumer repo.

**Aggregator calldata:** Harbor Option A — only 1inch v6 `swap` selector `0x07ed2379` is
accepted (`OneInchV6Selectors.SWAP`). Build via 1inch Swap API / Pathfinder.

**Known design tradeoffs** (documented in `src/swap/README.md`):

- `FxSaveWstEthSwapper_v1` intermediate Curve legs use `min_dy = 0`; only final wstETH
  output is bounded by the consumer's `minAmountOut`. Route changes require impl upgrade.
- `OneInchSwapper_v1` is open-access; authorization lives on the consumer's
  `executeAggregatorSwap` role gate. Selector allowlist does not validate swap parameters.

## License

MIT — see [LICENSE](LICENSE).

Third-party: Uniswap v3 periphery (GPL-2.0-or-later) is used by `UniV3Swapper_v1`.
