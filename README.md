# quiver-contracts

Quiver launchpad contracts for **Robinhood Chain** (chain ID 4663): pump.fun-style token
launches straight into **Uniswap v4** pools with permanently locked liquidity.

Based on [Clanker v4](https://github.com/clanker-devco/v4-contracts) (MIT, audited by
Cantina and Macro — reports in `audits/`), rebranded and adapted for Robinhood Chain:

- Superchain/ERC-7802, presale, and v3 dev-buy paths removed
- Protocol fee set to 30% of the LP fee (`PROTOCOL_FEE_NUMERATOR = 300_000`)
- Dependencies pinned to the exact commits the upstream audits covered

## Fee model (v1)

LP fee is set per pool (default 1%); the hook charges the protocol skim on top:

| Stream | % of volume |
|---|---|
| LP fee → reward recipients (creator; later creator + buyback) | ~1.00% |
| Protocol skim → factory → team | ~0.30% |

Note: the hook banks each swap's protocol fee as ERC-6909 claims and sweeps them to the
factory on the **next** swap in that pool — revenue accounting must expect a one-swap lag.

## Develop

```bash
make build     # compile
make test      # full suite (fork tests hit the live RPC)
make fork      # local anvil fork of Robinhood Chain
```

Tests fork mainnet state — there is no public testnet flow; see `test/LaunchE2E.t.sol`
for the full launch → trade → fee-claim lifecycle.

## Deploy (guarded)

```bash
cast wallet import deployer --interactive   # once: keystore account
make dry-run                                # simulate against live chain
TEAM_FEE_RECIPIENT=0x... OWNER=0x... make deploy
```

Deploys, wires, and Blockscout-verifies the stack. Launches stay **disabled**
(`factory.deprecated = true`) until deployed with `ACTIVATE=true` or the owner calls
`setDeprecated(false)` — this is the guarded-launch switch. Addresses are written to
`deployments/4663.json`.

Chain constants (RPC, Uniswap v4, WETH9) live in `script/RobinhoodChain.sol`.
Explorer is Blockscout (`robinhoodchain.blockscout.com`) — Etherscan does not index 4663.
