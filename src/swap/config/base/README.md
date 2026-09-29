# Base chain route configs

Chain-specific venue / path / fee / index constants for Base.

Mainnet route libraries remain at `src/swap/config/*_ETH_mainnet.sol` until a later
move into `config/mainnet/`. Aggregator adapters stay chain-agnostic under
`src/swap/aggregator/` (router address is a constructor arg).

Add Base route libraries here as `Config*Route_*.sol` when hyUSD (or other pegs)
are wired on Base.
