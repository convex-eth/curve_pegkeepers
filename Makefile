PYTHON ?= python3.11
VENV := .venv

.PHONY: setup build test clean

setup:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/python -m pip install -r requirements.txt
	git submodule update --init --recursive

build:
	forge build

test:
	forge test --force -vvv

clean:
	forge clean
