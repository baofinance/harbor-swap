# Robinhood chain route configs

Chain-specific venue / path / fee / index constants for Robinhood chain.

Mainnet route libraries remain at `src/swap/config/*_ETH_mainnet.sol` until a later
move into `config/mainnet/`. Aggregator adapters stay chain-agnostic under
`src/swap/aggregator/` (router address is a constructor arg).

Add Robinhood route libraries here as `Config*Route_*.sol` when hyUSD (or other pegs)
are wired on this chain.
