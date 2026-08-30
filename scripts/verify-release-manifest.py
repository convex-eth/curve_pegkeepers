#!/usr/bin/env python3
"""Verify committed PegKeeperV3 and immutable deployment-factory release evidence."""

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
FACTORY_ARTIFACT_PATH = ROOT / "out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json"
FACTORY_INTERFACE_ARTIFACT_PATH = ROOT / "out/IPegKeeperV3Factory.sol/IPegKeeperV3Factory.json"
FACTORY_SOURCE_PATH = ROOT / "src/vyper/PegKeeperV3Factory.vy"
EIP_170_LIMIT = 24_576
EIP_3860_LIMIT = 49_152
DEPLOYED_RUNTIME_BYTES = 22_862
FACTORY_DEPLOYED_RUNTIME_BYTES = 3_778
BLUEPRINT_PREAMBLE = bytes.fromhex("fe7100")
TESTS_PASSED = 206


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


def static_abi_words(parameter: dict[str, Any]) -> int:
    solidity_type = str(parameter["type"])
    if solidity_type == "tuple":
        return sum(static_abi_words(component) for component in parameter.get("components", []))
    if solidity_type.startswith("tuple") or solidity_type in ("bytes", "string") or "[" in solidity_type:
        raise SystemExit(f"unsupported dynamic constructor parameter: {solidity_type}")
    return 1


def constructor_args_bytes(abi: list[dict[str, Any]]) -> int:
    constructors = [entry for entry in abi if entry.get("type") == "constructor"]
    if len(constructors) != 1:
        raise SystemExit(f"expected one constructor ABI entry, got {len(constructors)}")
    return 32 * sum(static_abi_words(parameter) for parameter in constructors[0].get("inputs", []))


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
    factory_artifact = json.loads(FACTORY_ARTIFACT_PATH.read_text())
    factory_interface_artifact = json.loads(FACTORY_INTERFACE_ARTIFACT_PATH.read_text())
    source = SOURCE_PATH.read_bytes()
    factory_source = FACTORY_SOURCE_PATH.read_bytes()
    creation = bytecode(artifact, "bytecode")
    runtime = bytecode(artifact, "deployedBytecode")
    factory_creation = bytecode(factory_artifact, "bytecode")
    factory_runtime = bytecode(factory_artifact, "deployedBytecode")
    blueprint_runtime = BLUEPRINT_PREAMBLE + creation
    release_artifact = manifest["artifact"]
    release_factory = manifest["deploymentFactory"]
    release_factory_artifact = release_factory["artifact"]
    release_blueprint = release_factory["blueprint"]

    fail("release status", manifest["status"], "release_candidate_not_deployed")
    fail("source path", manifest["source"]["path"], str(SOURCE_PATH.relative_to(ROOT)))
    fail("artifact path", release_artifact["path"], str(ARTIFACT_PATH.relative_to(ROOT)))
    fail("source sha256", hashlib.sha256(source).hexdigest(), manifest["source"]["sha256"])
    fail("compiler creation size", len(creation), release_artifact["compilerCreationBytes"])
    fail(
        "compiler creation keccak",
        keccak256(creation),
        release_artifact["compilerCreationKeccak256"],
    )
    constructor_size = constructor_args_bytes(artifact["abi"])
    fail("constructor argument size", constructor_size, release_artifact["constructorArgsBytes"])
    full_initcode_bytes = len(creation) + constructor_size
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

    fail(
        "factory source sha256",
        hashlib.sha256(factory_source).hexdigest(),
        release_factory["source"]["sha256"],
    )
    fail(
        "factory source path",
        release_factory["source"]["path"],
        str(FACTORY_SOURCE_PATH.relative_to(ROOT)),
    )
    fail(
        "factory artifact path",
        release_factory_artifact["path"],
        str(FACTORY_ARTIFACT_PATH.relative_to(ROOT)),
    )
    fail(
        "factory compiler creation size",
        len(factory_creation),
        release_factory_artifact["compilerCreationBytes"],
    )
    fail(
        "factory compiler creation keccak",
        keccak256(factory_creation),
        release_factory_artifact["compilerCreationKeccak256"],
    )
    fail(
        "factory constructor argument size",
        constructor_args_bytes(factory_artifact["abi"]),
        release_factory_artifact["constructorArgsBytes"],
    )
    factory_full_initcode_bytes = len(factory_creation) + constructor_args_bytes(factory_artifact["abi"])
    fail(
        "factory full initcode size",
        factory_full_initcode_bytes,
        release_factory_artifact["fullInitCodeBytes"],
    )
    fail(
        "factory initcode limit",
        release_factory_artifact["eip3860LimitBytes"],
        EIP_3860_LIMIT,
    )
    fail(
        "factory full initcode margin",
        EIP_3860_LIMIT - factory_full_initcode_bytes,
        release_factory_artifact["fullInitCodeMarginBytes"],
    )
    fail(
        "factory runtime template size",
        len(factory_runtime),
        release_factory_artifact["runtimeTemplateBytes"],
    )
    fail(
        "factory runtime template keccak",
        keccak256(factory_runtime),
        release_factory_artifact["runtimeTemplateKeccak256"],
    )
    fail(
        "factory runtime limit",
        release_factory_artifact["eip170LimitBytes"],
        EIP_170_LIMIT,
    )
    fail(
        "factory deployed runtime size",
        FACTORY_DEPLOYED_RUNTIME_BYTES,
        release_factory_artifact["deployedRuntimeBytes"],
    )
    fail(
        "factory deployed runtime margin",
        EIP_170_LIMIT - FACTORY_DEPLOYED_RUNTIME_BYTES,
        release_factory_artifact["deployedRuntimeMarginBytes"],
    )
    factory_functions = sum(entry.get("type") == "function" for entry in factory_artifact["abi"])
    factory_events = sum(entry.get("type") == "event" for entry in factory_artifact["abi"])
    fail("factory ABI function count", factory_functions, release_factory_artifact["abiFunctions"])
    fail("factory ABI event count", factory_events, release_factory_artifact["abiEvents"])
    fail(
        "factory function ABI parity",
        function_abi(factory_artifact["abi"]),
        function_abi(factory_interface_artifact["abi"]),
    )
    fail(
        "factory event ABI parity",
        event_abi(factory_artifact["abi"]),
        event_abi(factory_interface_artifact["abi"]),
    )

    fail("blueprint format", release_blueprint["format"], "EIP-5202 version 0")
    fail("blueprint preamble", release_blueprint["preamble"], "0xfe7100")
    fail("blueprint runtime size", len(blueprint_runtime), release_blueprint["runtimeBytes"])
    fail(
        "blueprint runtime keccak",
        keccak256(blueprint_runtime),
        release_blueprint["runtimeKeccak256"],
    )
    fail("blueprint runtime limit", release_blueprint["eip170LimitBytes"], EIP_170_LIMIT)
    fail(
        "blueprint runtime margin",
        EIP_170_LIMIT - len(blueprint_runtime),
        release_blueprint["runtimeMarginBytes"],
    )
    if factory_full_initcode_bytes > EIP_3860_LIMIT:
        raise SystemExit("factory initcode exceeds EIP-3860")
    if FACTORY_DEPLOYED_RUNTIME_BYTES > EIP_170_LIMIT:
        raise SystemExit("factory runtime exceeds EIP-170")
    if len(blueprint_runtime) > EIP_170_LIMIT:
        raise SystemExit("blueprint runtime exceeds EIP-170")

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

    verification = manifest["verification"]
    fail("tests passed", verification["testsPassed"], TESTS_PASSED)
    fail("tests failed", verification["testsFailed"], 0)
    fail("tests skipped", verification["testsSkipped"], 0)
    for label in ("deploymentTest", "runtimeSizeTest", "abiParity", "releaseGates"):
        fail(label, verification[label], "pass")

    candidate_constructor = manifest["candidateConstructor"]
    candidate_defaults = release_factory["candidateDefaults"]
    fail("candidate factory owner pending", candidate_defaults["owner"], None)
    fail("candidate deployment factory pending", candidate_constructor["pegKeeperFactory"], None)
    fail(
        "candidate constructor keys",
        set(candidate_constructor),
        {
            "pegKeeperFactory",
            "targetAmm",
            "targetAsset",
            "backingAsset",
            "yieldToken",
            "maxDeployedCrvUsd",
            "operatorConfirmationRequired",
            "keeperIndex",
        },
    )
    fail(
        "candidate max deployed crvUSD",
        candidate_defaults["maxDeployedCrvUsd"],
        candidate_constructor["maxDeployedCrvUsd"],
    )
    zero_address = "0x0000000000000000000000000000000000000000"
    for label in ("controllerFactory", "admin", "emergencyAdmin", "feeReceiver"):
        if candidate_defaults[label] in (None, zero_address):
            raise SystemExit(f"candidate {label} must be a nonzero address")
    if candidate_defaults["admin"] == candidate_defaults["emergencyAdmin"]:
        raise SystemExit("candidate admin and emergency admin must differ")
    fail("candidate keeper index", candidate_constructor["keeperIndex"], 1)
    fail("candidate constructor confirmation", candidate_constructor["operatorConfirmationRequired"], True)
    fail("candidate confirmation", candidate_defaults["operatorConfirmationRequired"], True)

    source_commit = manifest["productionSourceCommit"]
    committed_source = subprocess.run(
        ["git", "show", f"{source_commit}:src/vyper/PegKeeperV3.vy"],
        check=True,
        cwd=ROOT,
        capture_output=True,
    ).stdout
    fail("production source commit", committed_source, source)
    committed_factory_source = subprocess.run(
        ["git", "show", f"{source_commit}:src/vyper/PegKeeperV3Factory.vy"],
        check=True,
        cwd=ROOT,
        capture_output=True,
    ).stdout
    fail("production factory source commit", committed_factory_source, factory_source)

    deployment = manifest["deployment"]
    fail("undeployed address", deployment["address"], None)
    fail("undeployed transaction", deployment["transactionHash"], None)
    fail("undeployed initcode hash", deployment["fullInitCodeKeccak256"], None)
    fail("undeployed code hash", deployment["deployedCodeKeccak256"], None)
    fail("undeployed factory debt ceiling", deployment["factoryDebtCeiling"], None)
    fail("deployment verification", deployment["verified"], False)
    fail("activation status", deployment["activated"], False)

    factory_deployment = release_factory["deployment"]
    fail("undeployed blueprint address", factory_deployment["blueprintAddress"], None)
    fail("undeployed factory address", factory_deployment["factoryAddress"], None)
    fail("undeployed factory transaction", factory_deployment["transactionHash"], None)
    fail("factory deployment verification", factory_deployment["verified"], False)

    latest_canary = manifest["latestMainnetCanary"]
    fail("canary script", latest_canary["script"], "script/PegKeeperV3ReleaseCanary.s.sol")
    fail("canary result", latest_canary["result"], "pass")
    fail("canary broadcast", latest_canary["broadcast"], False)

    print(
        "PegKeeperV3 release manifest verified: "
        f"runtime={DEPLOYED_RUNTIME_BYTES} margin={EIP_170_LIMIT - DEPLOYED_RUNTIME_BYTES} "
        f"initcode={full_initcode_bytes} "
        f"functions={functions} events={events} "
        f"factory_runtime={FACTORY_DEPLOYED_RUNTIME_BYTES} "
        f"blueprint_runtime={len(blueprint_runtime)}"
    )


if __name__ == "__main__":
    main()
