#!/usr/bin/env python3
"""Compare a Vyper artifact ABI with a Solidity interface artifact ABI."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def load_abi(path: str) -> list[dict[str, Any]]:
    payload = json.loads(Path(path).read_text())
    abi = payload.get("abi", payload)
    if not isinstance(abi, list):
        raise ValueError(f"{path}: expected an ABI list or artifact with an 'abi' list")
    return abi


def canonical_type(param: dict[str, Any]) -> str:
    token_type = param["type"]
    if token_type.startswith("tuple"):
        suffix = token_type[5:]
        components = ",".join(canonical_type(item) for item in param.get("components", []))
        return f"({components}){suffix}"
    return token_type


def signature(entry: dict[str, Any]) -> str:
    inputs = ",".join(canonical_type(item) for item in entry.get("inputs", []))
    return f"{entry['name']}({inputs})"


def canonical_param(param: dict[str, Any], *, event: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {"type": param["type"]}
    if "components" in param:
        result["components"] = [canonical_param(item, event=event) for item in param["components"]]
    if event:
        result["indexed"] = bool(param.get("indexed", False))
    return result


def canonical_function(entry: dict[str, Any]) -> dict[str, Any]:
    return {
        "inputs": [canonical_param(item) for item in entry.get("inputs", [])],
        "outputs": [canonical_param(item) for item in entry.get("outputs", [])],
        "stateMutability": entry.get("stateMutability", "nonpayable"),
    }


def canonical_event(entry: dict[str, Any]) -> dict[str, Any]:
    return {
        "inputs": [canonical_param(item, event=True) for item in entry.get("inputs", [])],
        "anonymous": bool(entry.get("anonymous", False)),
    }


def collect(abi: list[dict[str, Any]], kind: str) -> dict[str, dict[str, Any]]:
    canonicalizer = canonical_function if kind == "function" else canonical_event
    return {
        signature(entry): canonicalizer(entry)
        for entry in abi
        if entry.get("type") == kind
    }


def entries_match(left: dict[str, Any], right: dict[str, Any], kind: str) -> bool:
    if left == right:
        return True
    if kind != "function":
        return False
    left_adjusted = dict(left)
    right_adjusted = dict(right)
    if (
        left_adjusted.get("stateMutability") in {"pure", "view"}
        and right_adjusted.get("stateMutability") in {"pure", "view"}
    ):
        left_adjusted["stateMutability"] = "readonly"
        right_adjusted["stateMutability"] = "readonly"
    return left_adjusted == right_adjusted


def compare(
    left: dict[str, dict[str, Any]],
    right: dict[str, dict[str, Any]],
    kind: str,
) -> dict[str, Any]:
    left_keys = set(left)
    right_keys = set(right)
    return {
        "vyper_count": len(left),
        "interface_count": len(right),
        "signature_diff": sorted(left_keys ^ right_keys),
        "semantic_mismatch": [
            key
            for key in sorted(left_keys & right_keys)
            if not entries_match(left[key], right[key], kind)
        ],
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"usage: {Path(sys.argv[0]).name} <vyper-artifact.json> <interface-artifact.json>",
            file=sys.stderr,
        )
        return 2

    vyper_abi = load_abi(sys.argv[1])
    interface_abi = load_abi(sys.argv[2])
    report: dict[str, Any] = {
        "functions": compare(
            collect(vyper_abi, "function"), collect(interface_abi, "function"), "function"
        ),
        "events": compare(
            collect(vyper_abi, "event"), collect(interface_abi, "event"), "event"
        ),
    }
    report["passed"] = all(
        not section["signature_diff"] and not section["semantic_mismatch"]
        for section in (report["functions"], report["events"])
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
