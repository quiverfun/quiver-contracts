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

.PHONY: build test test-e2e dry-run deploy redeploy-devbuy-dry redeploy-devbuy launch verify-help fork verify-json

build:
	forge build

test:
	forge test

test-e2e:
	forge test --match-contract LaunchE2E -vv

# simulate the full deployment against live chain state, no broadcast
dry-run:
	forge script script/Deploy.s.sol --rpc-url $(RPC)

# ---- v3 stack (plain Uniswap v3 pools — no hooks; see src/v3/) ----
dry-run-v3:
	forge script script/DeployV3.s.sol --rpc-url $(RPC)

deploy-v3:
	forge script script/DeployV3.s.sol \
		--rpc-url $(RPC) \
		--account $(ACCOUNT) \
		--broadcast \
		--verify \
		--verifier blockscout \
		--verifier-url $(VERIFIER_URL) \
		--slow

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

# replace the devBuy extension on the live factory (owner account required);
# the original build's router encoding reverts on chain 4663 — see
# script/RedeployDevBuy.s.sol. Dry run simulates as the recorded owner.
redeploy-devbuy-dry:
	forge script script/RedeployDevBuy.s.sol --rpc-url $(RPC) \
		--sender $$(python3 -c "import json;print(json.load(open('deployments/4663.json'))['owner'])")

redeploy-devbuy:
	forge script script/RedeployDevBuy.s.sol \
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

# regenerate the standard-JSON compiler input the indexer uses to auto-verify
# launched tokens on Blockscout. Run this after ANY factory redeploy that
# changes QuiverToken bytecode (the JSON must match the live factory's tokens),
# then rebuild the indexer (docker compose up -d --build in quiver-app).
verify-json:
	forge verify-contract 0x0000000000000000000000000000000000000000 \
		src/QuiverToken.sol:QuiverToken --show-standard-json-input \
		> ../quiver-app/shared/quiver-token.standard-input.json
	@echo "wrote quiver-app/shared/quiver-token.standard-input.json"

# local mainnet fork for app/indexer development
fork:
	anvil --fork-url $(RPC) --port 8545
