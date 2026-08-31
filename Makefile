PYTHON ?= python3.11
VENV := .venv

.PHONY: setup build test check release-canary clean

setup:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/python -m pip install -r requirements.txt
	git submodule update --init --recursive

build:
	forge build

test:
	forge test --force -vvv

check:
	forge fmt --check
	git diff --check
	forge lint
	forge build
	forge build --sizes
	python3 scripts/check-vyper-solidity-abi.py \
		out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json \
		out/IPegKeeperV3PreviewModule.sol/IPegKeeperV3PreviewModule.json
	python3 scripts/check-vyper-solidity-abi.py \
		out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json \
		out/IChainlinkStablecoinOracle.sol/IChainlinkStablecoinOracle.json
	python3 scripts/verify-release-manifest.py
	$(MAKE) test

release-canary:
	@test -n "$$ETH_RPC_URL" || (printf '%s\n' 'ETH_RPC_URL is required' >&2; exit 1)
	@forge script script/PegKeeperV3ReleaseCanary.s.sol:PegKeeperV3ReleaseCanary --rpc-url "$$ETH_RPC_URL" -vv

clean:
	forge clean
