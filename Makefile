# Quiver contracts — Robinhood Chain (4663)
#
# Deployment requires a funded account. Use a Foundry keystore account
# (`cast wallet import deployer --interactive`) — never a raw private key in env.
#
# Optional env for deploy:
#   TEAM_FEE_RECIPIENT  protocol fee recipient (default: deployer)
#   OWNER               final owner, e.g. a multisig (default: deployer)
#   ACTIVATE            "true" to enable launches immediately (default: guarded/off)

RPC            := https://rpc.mainnet.chain.robinhood.com
VERIFIER_URL   := https://robinhoodchain.blockscout.com/api/
ACCOUNT        ?= deployer

.PHONY: build test test-e2e dry-run deploy launch verify-help fork

build:
	forge build

test:
	forge test

test-e2e:
	forge test --match-contract LaunchE2E -vv

# simulate the full deployment against live chain state, no broadcast
dry-run:
	forge script script/Deploy.s.sol --rpc-url $(RPC)

# broadcast + verify every contract on Blockscout in one go
deploy:
	forge script script/Deploy.s.sol \
		--rpc-url $(RPC) \
		--account $(ACCOUNT) \
		--broadcast \
		--verify \
		--verifier blockscout \
		--verifier-url $(VERIFIER_URL) \
		--slow

# launch one token through the deployed factory
# usage: NAME="My Token" SYMBOL=MINE make launch
launch:
	forge script script/Launch.s.sol \
		--rpc-url $(RPC) \
		--account $(ACCOUNT) \
		--broadcast \
		--slow

# verify a single contract after the fact (if --verify was interrupted)
# usage: make verify-help
verify-help:
	@echo "forge verify-contract <address> <src path>:<contract> \\"
	@echo "  --chain-id 4663 --verifier blockscout --verifier-url $(VERIFIER_URL)"

# local mainnet fork for app/indexer development
fork:
	anvil --fork-url $(RPC) --port 8545
