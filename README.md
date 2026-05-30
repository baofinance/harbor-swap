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

## License

MIT — see [LICENSE](LICENSE).

Third-party: Uniswap v3 periphery (GPL-2.0-or-later) is used by `UniV3Swapper_v1`.
