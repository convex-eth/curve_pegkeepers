#!/usr/bin/env python3
"""Verify that the committed PegKeeperV3 release manifest matches the built artifact."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "deployments/mainnet/PegKeeperV3-release.json"
ARTIFACT_PATH = ROOT / "out/PegKeeperV3.vy/PegKeeperV3.json"
INTERFACE_ARTIFACT_PATH = ROOT / "out/IPegKeeperV3.sol/IPegKeeperV3.json"
SOURCE_PATH = ROOT / "src/vyper/PegKeeperV3.vy"
EIP_170_LIMIT = 24_576
EIP_3860_LIMIT = 49_152
CONSTRUCTOR_ARGS_BYTES = 9 * 32
DEPLOYED_RUNTIME_BYTES = 22_077


def fail(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise SystemExit(f"{label}: expected {expected!r}, got {actual!r}")


def bytecode(artifact: dict[str, Any], key: str) -> bytes:
    value = artifact[key]["object"]  # type: ignore[index]
    if value.startswith("0x"):
        value = value[2:]
    return bytes.fromhex(value)


def keccak256(value: bytes) -> str:
    result = subprocess.run(
        ["cast", "keccak", "0x" + value.hex()],
        check=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def canonical_type(parameter: dict[str, Any]) -> str:
    solidity_type = str(parameter["type"])
    if not solidity_type.startswith("tuple"):
        return solidity_type
    suffix = solidity_type[5:]
    components = parameter.get("components", [])
    return "(" + ",".join(canonical_type(component) for component in components) + ")" + suffix


def function_abi(abi: list[dict[str, Any]]) -> dict[str, tuple[object, ...]]:
    result: dict[str, tuple[object, ...]] = {}
    for entry in abi:
        if entry.get("type") != "function":
            continue
        signature = str(entry["name"]) + "(" + ",".join(
            canonical_type(parameter) for parameter in entry.get("inputs", [])
        ) + ")"
        outputs = tuple(canonical_type(parameter) for parameter in entry.get("outputs", []))
        mutability = entry.get("stateMutability")
        if mutability in ("pure", "view"):
            mutability = "readonly"
        result[signature] = (mutability, outputs)
    return result


def event_abi(abi: list[dict[str, Any]]) -> dict[str, tuple[object, ...]]:
    result: dict[str, tuple[object, ...]] = {}
    for entry in abi:
        if entry.get("type") != "event":
            continue
        inputs = entry.get("inputs", [])
        signature = str(entry["name"]) + "(" + ",".join(
            canonical_type(parameter) for parameter in inputs
        ) + ")"
        result[signature] = (
            entry.get("anonymous", False),
            tuple(bool(parameter.get("indexed")) for parameter in inputs),
        )
    return result


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text())
    artifact = json.loads(ARTIFACT_PATH.read_text())
    interface_artifact = json.loads(INTERFACE_ARTIFACT_PATH.read_text())
    source = SOURCE_PATH.read_bytes()
    creation = bytecode(artifact, "bytecode")
    runtime = bytecode(artifact, "deployedBytecode")
    release_artifact = manifest["artifact"]

    fail("release status", manifest["status"], "release_candidate_not_deployed")
    fail("source sha256", hashlib.sha256(source).hexdigest(), manifest["source"]["sha256"])
    fail("compiler creation size", len(creation), release_artifact["compilerCreationBytes"])
    fail(
        "compiler creation keccak",
        keccak256(creation),
        release_artifact["compilerCreationKeccak256"],
    )
    fail("constructor argument size", CONSTRUCTOR_ARGS_BYTES, release_artifact["constructorArgsBytes"])
    full_initcode_bytes = len(creation) + CONSTRUCTOR_ARGS_BYTES
    fail("full initcode size", full_initcode_bytes, release_artifact["fullInitCodeBytes"])
    fail("initcode limit", release_artifact["eip3860LimitBytes"], EIP_3860_LIMIT)
    fail(
        "full initcode margin",
        EIP_3860_LIMIT - full_initcode_bytes,
        release_artifact["fullInitCodeMarginBytes"],
    )
    fail("runtime template size", len(runtime), release_artifact["runtimeTemplateBytes"])
    fail(
        "runtime template keccak",
        keccak256(runtime),
        release_artifact["runtimeTemplateKeccak256"],
    )
    fail("runtime limit", release_artifact["eip170LimitBytes"], EIP_170_LIMIT)
    fail("deployed runtime size", DEPLOYED_RUNTIME_BYTES, release_artifact["deployedRuntimeBytes"])
    fail(
        "deployed runtime margin",
        EIP_170_LIMIT - DEPLOYED_RUNTIME_BYTES,
        release_artifact["deployedRuntimeMarginBytes"],
    )
    if DEPLOYED_RUNTIME_BYTES > EIP_170_LIMIT:
        raise SystemExit(
            f"deployed runtime exceeds EIP-170: {DEPLOYED_RUNTIME_BYTES} > {EIP_170_LIMIT}"
        )

    functions = sum(entry.get("type") == "function" for entry in artifact["abi"])
    events = sum(entry.get("type") == "event" for entry in artifact["abi"])
    fail("ABI function count", functions, release_artifact["abiFunctions"])
    fail("ABI event count", events, release_artifact["abiEvents"])
    fail("function ABI parity", function_abi(artifact["abi"]), function_abi(interface_artifact["abi"]))
    fail("event ABI parity", event_abi(artifact["abi"]), event_abi(interface_artifact["abi"]))

    config = tomllib.loads((ROOT / "foundry.toml").read_text())
    fail("Solidity version", config["profile"]["default"]["solc_version"], manifest["verification"]["solidityVersion"])
    fail("EVM version", config["profile"]["default"]["evm_version"], manifest["compiler"]["evmVersion"])
    fail("Vyper optimizer", config["vyper"]["optimize"], manifest["compiler"]["optimizer"])
    fail("Vyper path", config["vyper"]["path"], ".venv/bin/vyper")
    vyper_version = subprocess.run(
        [str(ROOT / config["vyper"]["path"]), "--version"],
        check=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.strip()
    fail("Vyper version", vyper_version, manifest["compiler"]["version"])

    source_commit = manifest["productionSourceCommit"]
    committed_source = subprocess.run(
        ["git", "show", f"{source_commit}:src/vyper/PegKeeperV3.vy"],
        check=True,
        cwd=ROOT,
        capture_output=True,
    ).stdout
    fail("production source commit", committed_source, source)

    deployment = manifest["deployment"]
    fail("undeployed address", deployment["address"], None)
    fail("undeployed transaction", deployment["transactionHash"], None)
    fail("undeployed initcode hash", deployment["fullInitCodeKeccak256"], None)
    fail("undeployed code hash", deployment["deployedCodeKeccak256"], None)
    fail("deployment verification", deployment["verified"], False)
    fail("activation status", deployment["activated"], False)

    print(
        "PegKeeperV3 release manifest verified: "
        f"runtime={DEPLOYED_RUNTIME_BYTES} margin={EIP_170_LIMIT - DEPLOYED_RUNTIME_BYTES} "
        f"initcode={full_initcode_bytes} "
        f"functions={functions} events={events}"
    )


if __name__ == "__main__":
    main()
