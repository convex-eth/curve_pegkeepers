#!/usr/bin/env python3
"""Fail-closed verification for the undeployed PegKeeperV3 proxy-era release package."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tomllib
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "deployments/mainnet/PegKeeperV3-release.json"
EIP_170_LIMIT = 24_576
EIP_3860_LIMIT = 49_152
REFACTORED_IMPLEMENTATION_RUNTIME_BUDGET = 22_300
EXPECTED_TESTS = 248

ARTIFACTS = {
    "implementation": (
        ROOT / "src/vyper/PegKeeperV3.vy",
        ROOT / "out/PegKeeperV3.vy/PegKeeperV3.json",
        ROOT / "out/IPegKeeperV3.sol/IPegKeeperV3.json",
    ),
    "factory": (
        ROOT / "src/vyper/PegKeeperV3Factory.vy",
        ROOT / "out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json",
        ROOT / "out/IPegKeeperV3Factory.sol/IPegKeeperV3Factory.json",
    ),
    "preview": (
        ROOT / "src/vyper/PegKeeperV3PreviewModule.vy",
        ROOT / "out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json",
        ROOT / "out/IPegKeeperV3PreviewModule.sol/IPegKeeperV3PreviewModule.json",
    ),
    "curve": (
        ROOT / "src/vyper/CurveStablecoinOracle.vy",
        ROOT / "out/CurveStablecoinOracle.vy/CurveStablecoinOracle.json",
        ROOT / "out/ICurveStablecoinOracle.sol/ICurveStablecoinOracle.json",
    ),
    "chainlink": (
        ROOT / "src/vyper/ChainlinkStablecoinOracle.vy",
        ROOT / "out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json",
        ROOT / "out/IChainlinkStablecoinOracle.sol/IChainlinkStablecoinOracle.json",
    ),
}


def fail(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise SystemExit(f"{label}: expected {expected!r}, got {actual!r}")


def fail_keys(label: str, actual: dict[str, Any], expected: set[str]) -> None:
    fail(f"{label} fields", set(actual), expected)


def bytecode(artifact: dict[str, Any], key: str) -> bytes:
    value = artifact[key]["object"]
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


def verify_source_commit(source_commit: str, path: Path) -> None:
    relative = str(path.relative_to(ROOT))
    committed = subprocess.run(
        ["git", "show", f"{source_commit}:{relative}"],
        check=True,
        cwd=ROOT,
        capture_output=True,
    ).stdout
    fail(f"production source commit {relative}", committed, path.read_bytes())


def artifact_counts(artifact: dict[str, Any]) -> tuple[int, int]:
    functions = sum(entry.get("type") == "function" for entry in artifact["abi"])
    events = sum(entry.get("type") == "event" for entry in artifact["abi"])
    return functions, events


def verify_artifact(
    label: str,
    section: dict[str, Any],
    source_path: Path,
    artifact_path: Path,
    interface_path: Path | None,
    creation_size_key: str,
    creation_hash_key: str,
    runtime_size_key: str,
    runtime_hash_key: str,
) -> tuple[dict[str, Any], bytes, bytes]:
    artifact = json.loads(artifact_path.read_text())
    creation = bytecode(artifact, "bytecode")
    runtime = bytecode(artifact, "deployedBytecode")
    source = section["source"]
    release_artifact = section["artifact"]

    fail(f"{label} source path", source["path"], str(source_path.relative_to(ROOT)))
    fail(f"{label} source sha256", hashlib.sha256(source_path.read_bytes()).hexdigest(), source["sha256"])
    fail(f"{label} artifact path", release_artifact["path"], str(artifact_path.relative_to(ROOT)))
    fail(f"{label} creation bytes", len(creation), release_artifact[creation_size_key])
    fail(f"{label} creation hash", keccak256(creation), release_artifact[creation_hash_key])
    fail(f"{label} runtime bytes", len(runtime), release_artifact[runtime_size_key])
    fail(f"{label} runtime hash", keccak256(runtime), release_artifact[runtime_hash_key])

    functions, events = artifact_counts(artifact)
    if "abiFunctions" in release_artifact:
        fail(f"{label} ABI functions", functions, release_artifact["abiFunctions"])
    if "abiEvents" in release_artifact:
        fail(f"{label} ABI events", events, release_artifact["abiEvents"])
    if interface_path is not None:
        interface = json.loads(interface_path.read_text())
        fail(f"{label} function ABI parity", function_abi(artifact["abi"]), function_abi(interface["abi"]))
        fail(f"{label} event ABI parity", event_abi(artifact["abi"]), event_abi(interface["abi"]))
    return artifact, creation, runtime


def listed_test_count() -> int:
    result = subprocess.run(
        ["forge", "test", "--list", "--json"],
        check=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    suites = json.loads(result.stdout)
    return sum(
        len(tests)
        for contracts in suites.values()
        if isinstance(contracts, dict)
        for tests in contracts.values()
        if isinstance(tests, list)
    )


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text())
    fail("release status", manifest["status"], "release_candidate_not_deployed")
    fail("repository", manifest["repository"], "git@github.com:convex-eth/curve_pegkeepers.git")
    remote = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        check=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.strip()
    fail("origin remote", remote, manifest["repository"])
    source_commit = manifest["productionSourceCommit"]
    subprocess.run(
        ["git", "merge-base", "--is-ancestor", source_commit, "HEAD"],
        check=True,
        cwd=ROOT,
    )
    expected_evidence_drift = [
        "deployments/mainnet/PegKeeperV3-release.json",
        "docs/pegkeeper-v3-release-checklist.md",
        "scripts/verify-release-manifest.py",
    ]
    actual_drift = subprocess.run(
        ["git", "diff", "--name-only", source_commit, "--"],
        check=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    fail("tracked drift from production source commit", actual_drift, expected_evidence_drift)
    generated_at = datetime.fromisoformat(manifest["generatedAtUtc"].replace("Z", "+00:00"))
    source_commit_time = datetime.fromisoformat(
        subprocess.run(
            ["git", "show", "-s", "--format=%cI", source_commit],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )
    if generated_at < source_commit_time:
        raise SystemExit(
            f"manifest generated before source commit: {generated_at.isoformat()} < {source_commit_time.isoformat()}"
        )

    implementation, impl_creation, impl_runtime = verify_artifact(
        "implementation",
        manifest["implementation"],
        ARTIFACTS["implementation"][0],
        ARTIFACTS["implementation"][1],
        ARTIFACTS["implementation"][2],
        "compilerCreationBytes",
        "compilerCreationKeccak256",
        "semanticCoreRuntimeBytes",
        "semanticCoreRuntimeKeccak256",
    )
    preview, preview_creation, preview_runtime = verify_artifact(
        "preview",
        manifest["previewModule"],
        ARTIFACTS["preview"][0],
        ARTIFACTS["preview"][1],
        ARTIFACTS["preview"][2],
        "creationBytes",
        "creationKeccak256",
        "runtimeBytes",
        "runtimeKeccak256",
    )
    factory, factory_creation, factory_runtime = verify_artifact(
        "factory",
        manifest["deploymentFactory"],
        ARTIFACTS["factory"][0],
        ARTIFACTS["factory"][1],
        ARTIFACTS["factory"][2],
        "compilerCreationBytes",
        "compilerCreationKeccak256",
        "runtimeTemplateBytes",
        "runtimeTemplateKeccak256",
    )
    curve, _, curve_runtime = verify_artifact(
        "Curve oracle",
        manifest["oraclePolicy"]["curve"],
        ARTIFACTS["curve"][0],
        ARTIFACTS["curve"][1],
        ARTIFACTS["curve"][2],
        "compilerCreationBytes",
        "compilerCreationKeccak256",
        "runtimeTemplateBytes",
        "runtimeTemplateKeccak256",
    )
    chainlink, _, chainlink_runtime = verify_artifact(
        "Chainlink oracle",
        manifest["oraclePolicy"]["chainlink"],
        ARTIFACTS["chainlink"][0],
        ARTIFACTS["chainlink"][1],
        ARTIFACTS["chainlink"][2],
        "compilerCreationBytes",
        "compilerCreationKeccak256",
        "runtimeTemplateBytes",
        "runtimeTemplateKeccak256",
    )

    for key in ("implementation", "factory", "preview", "curve", "chainlink"):
        verify_source_commit(source_commit, ARTIFACTS[key][0])
    for script in (
        ROOT / "script/DeployPegKeeperV3.s.sol",
        ROOT / "script/PegKeeperV3ReleaseCanary.s.sol",
        ROOT / "script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol",
    ):
        verify_source_commit(source_commit, script)

    deploy_script_path = ROOT / "script/DeployPegKeeperV3.s.sol"
    proposal_script_path = ROOT / "script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol"
    deploy_script = deploy_script_path.read_text()
    proposal_script = proposal_script_path.read_text()
    fail(
        "unified deployment script inventory",
        sorted(str(path.relative_to(ROOT)) for path in (ROOT / "script").glob("DeployPegKeeperV3*.s.sol")),
        ["script/DeployPegKeeperV3.s.sol"],
    )
    for forbidden in ("vm.env", "PKV3_"):
        if forbidden in deploy_script or forbidden in proposal_script:
            raise SystemExit(f"environment-driven deployment input present: {forbidden}")

    create_markers = [
        "_deployPreviewModule()",
        "_deployImplementation(deployment.previewModule)",
        "_deployFactory(config, deployment.implementation)",
        "deployment.usdcTargetOracle =",
        "deployment.usdtTargetOracle =",
        "deployment.frxUsdUsdOracle =",
        "deployment.usdsUsdOracle =",
    ]
    create_positions = [deploy_script.find(marker) for marker in create_markers]
    if -1 in create_positions or create_positions != sorted(create_positions):
        raise SystemExit("unified deployment CREATE order drift")

    deployment_fields = [
        "previewModule",
        "implementation",
        "factory",
        "usdcTargetOracle",
        "usdtTargetOracle",
        "frxUsdUsdOracle",
        "usdsUsdOracle",
    ]
    if 'vm.serializeUint(objectKey, "chainId", block.chainid)' not in deploy_script:
        raise SystemExit("deployment JSON chainId missing")
    for field in deployment_fields:
        if f'vm.serializeAddress(objectKey, "{field}"' not in deploy_script:
            raise SystemExit(f"deployment JSON field missing: {field}")
    if 'vm.parseJsonUint(json, ".chainId") == block.chainid' not in proposal_script:
        raise SystemExit("proposal deployment chain binding missing")
    for field in deployment_fields[2:]:
        if f'vm.parseJsonAddress(json, ".{field}")' not in proposal_script:
            raise SystemExit(f"proposal deployment field missing: {field}")
    obsolete_deployment_fields = (
        "frxUsdTargetOracle",
        "sfrxUsdBackingOracle",
        "susdsBackingOracle",
        "frxUsdChainlinkOracle",
        "usdsChainlinkOracle",
    )
    for field in obsolete_deployment_fields:
        if field in deploy_script or field in proposal_script:
            raise SystemExit(f"obsolete alternative-oracle deployment field present: {field}")

    impl_release = manifest["implementation"]["artifact"]
    fail("implementation constructor args", impl_release["constructorArgsBytes"], 32)
    fail("implementation initcode", len(impl_creation) + 32, impl_release["fullInitCodeBytes"])
    fail("implementation initcode limit", impl_release["eip3860LimitBytes"], EIP_3860_LIMIT)
    fail("implementation initcode margin", EIP_3860_LIMIT - len(impl_creation) - 32, impl_release["fullInitCodeMarginBytes"])
    fail("implementation deployed runtime", len(impl_runtime) + 32, impl_release["deployedRuntimeBytes"])
    fail("implementation runtime limit", impl_release["eip170LimitBytes"], EIP_170_LIMIT)
    fail("implementation runtime margin", EIP_170_LIMIT - len(impl_runtime) - 32, impl_release["deployedRuntimeMarginBytes"])
    if len(impl_runtime) + 32 > REFACTORED_IMPLEMENTATION_RUNTIME_BUDGET:
        raise SystemExit(
            "implementation refactor budget exceeded: "
            f"{len(impl_runtime) + 32} > {REFACTORED_IMPLEMENTATION_RUNTIME_BUDGET}"
        )
    fail(
        "implementation operational initialization lock",
        manifest["implementation"]["lockedAgainstOperationalInitialization"],
        True,
    )
    if len(impl_runtime) + 32 > EIP_170_LIMIT:
        raise SystemExit("implementation exceeds EIP-170")

    preview_release = manifest["previewModule"]["artifact"]
    fail("preview runtime limit", preview_release["eip170LimitBytes"], EIP_170_LIMIT)
    fail("preview runtime margin", EIP_170_LIMIT - len(preview_runtime), preview_release["runtimeMarginBytes"])
    fail("preview stateless", manifest["previewModule"]["stateless"], True)
    fail("preview keeper binding", manifest["previewModule"]["keeperIdentityBound"], True)

    factory_release = manifest["deploymentFactory"]["artifact"]
    fail("factory constructor args", factory_release["constructorArgsBytes"], 352)
    fail("factory initcode", len(factory_creation) + 352, factory_release["fullInitCodeBytes"])
    fail("factory initcode limit", factory_release["eip3860LimitBytes"], EIP_3860_LIMIT)
    fail("factory initcode margin", EIP_3860_LIMIT - len(factory_creation) - 352, factory_release["fullInitCodeMarginBytes"])
    fail("factory deployed runtime", len(factory_runtime) + 64, factory_release["deployedRuntimeBytes"])
    fail("factory runtime limit", factory_release["eip170LimitBytes"], EIP_170_LIMIT)
    fail("factory runtime margin", EIP_170_LIMIT - len(factory_runtime) - 64, factory_release["deployedRuntimeMarginBytes"])
    fail("factory immutable implementation", manifest["deploymentFactory"]["implementationImmutableAfterConstruction"], True)
    fail("factory implementation setter", manifest["deploymentFactory"]["implementationSetterPresent"], False)
    if len(factory_runtime) + 64 > EIP_170_LIMIT:
        raise SystemExit("factory exceeds EIP-170")

    expected_error_selectors = {
        "NotOwner()": "0x30cd7471",
        "NotPendingOwner()": "0x1853971c",
        "InvalidOwner()": "0x49e27cff",
        "InvalidImplementation()": "0x68155f9a",
        "InvalidDefaults()": "0xa7f2ca4b",
        "InvalidTargetAmm()": "0xf871d4c8",
        "DeploymentFailed()": "0x30116425",
    }
    fail(
        "legacy factory errors",
        sorted(manifest["deploymentFactory"]["legacyCustomErrors"]),
        sorted(expected_error_selectors),
    )
    factory_source = ARTIFACTS["factory"][0].read_text()
    for signature, selector in expected_error_selectors.items():
        if f'method_id("{signature}")' not in factory_source:
            raise SystemExit(f"factory error missing from source: {signature}")
        actual_selector = subprocess.run(
            ["cast", "sig", signature],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        ).stdout.strip()
        fail(f"factory error selector {signature}", actual_selector, selector)

    proxy = manifest["minimalProxy"]
    fail("proxy standard", proxy["standard"], "EIP-1167")
    fail("proxy initcode bytes", proxy["initCodeBytes"], 55)
    fail("proxy runtime bytes", proxy["runtimeBytes"], 45)
    fail("proxy runtime margin", EIP_170_LIMIT - 45, proxy["runtimeMarginBytes"])
    fail("proxy creates", proxy["createsPerKeeper"], 1)
    for flag in ("proxyAdminPresent", "upgradeSlotPresent", "implementationSetterPresent"):
        fail(flag, proxy[flag], False)
    fail("proxy atomic initialization", proxy["atomicFactoryInitialization"], True)

    if "blueprint" in manifest or "blueprint" in manifest["deploymentFactory"]:
        raise SystemExit("obsolete blueprint evidence present")

    oracle = manifest["oraclePolicy"]
    fail_keys(
        "oracle policy",
        oracle,
        {
            "selectionStatus",
            "releaseBlockedUntilSelection",
            "commonPriceDecimals",
            "favorablePriceCap",
            "minimumLaunchPrice",
            "curve",
            "chainlink",
            "proposalBindings",
        },
    )
    fail_keys(
        "Curve oracle policy",
        oracle["curve"],
        {"source", "artifact", "deploymentScript", "adapters"},
    )
    fail_keys(
        "Chainlink oracle policy",
        oracle["chainlink"],
        {
            "source",
            "artifact",
            "deploymentScript",
            "adapters",
            "directProxyReadsSupported",
            "underlyingAggregatorRotationSupported",
            "maxDelayStatus",
        },
    )
    for index, adapter in enumerate(oracle["curve"]["adapters"]):
        fail_keys(
            f"Curve adapter {index}",
            adapter,
            {"role", "pool", "asset", "referenceAsset", "inverted"},
        )
    for index, adapter in enumerate(oracle["chainlink"]["adapters"]):
        fail_keys(
            f"Chainlink adapter {index}",
            adapter,
            {
                "role",
                "ens",
                "proxy",
                "officialListing",
                "deviationThresholdBps",
                "heartbeatSeconds",
                "feedDecimals",
                "maxDelay",
            },
        )
    for index, binding in enumerate(oracle["proposalBindings"]):
        fail_keys(
            f"proposal oracle binding {index}",
            binding,
            {"keeper", "targetOracle", "downstreamOracle"},
        )
    fail(
        "oracle selection",
        oracle["selectionStatus"],
        "selected_chainlink_for_frxusd_usds",
    )
    fail("oracle selection blocker", oracle["releaseBlockedUntilSelection"], False)
    fail("oracle precision", oracle["commonPriceDecimals"], 18)
    fail("oracle par cap", oracle["favorablePriceCap"], "1000000000000000000")
    fail("oracle floor", oracle["minimumLaunchPrice"], "999700000000000000")
    fail("Curve adapter count", len(oracle["curve"]["adapters"]), 2)
    fail("Chainlink adapter count", len(oracle["chainlink"]["adapters"]), 2)
    fail("Curve deployment script", oracle["curve"]["deploymentScript"], "script/DeployPegKeeperV3.s.sol")
    fail(
        "Curve adapter mappings",
        [
            {
                "role": adapter["role"],
                "pool": adapter["pool"].lower(),
                "asset": adapter["asset"].lower(),
                "referenceAsset": adapter["referenceAsset"].lower(),
                "inverted": adapter["inverted"],
            }
            for adapter in oracle["curve"]["adapters"]
        ],
        [
            {"role": "USDC target", "pool": "0x4f493b7de8aac7d55f71853688b1f7c8f0243c85", "asset": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "referenceAsset": "0xdac17f958d2ee523a2206206994597c13d831ec7", "inverted": True},
            {"role": "USDT target", "pool": "0x4f493b7de8aac7d55f71853688b1f7c8f0243c85", "asset": "0xdac17f958d2ee523a2206206994597c13d831ec7", "referenceAsset": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "inverted": False},
        ],
    )
    fail(
        "Chainlink deployment script",
        oracle["chainlink"]["deploymentScript"],
        "script/DeployPegKeeperV3.s.sol",
    )
    chainlink_release = oracle["chainlink"]
    for obsolete in (
        "registry",
        "quote",
        "directFeedContractReadsSupported",
        "feedRotationFailsClosed",
    ):
        if obsolete in chainlink_release:
            raise SystemExit(f"obsolete Chainlink registry evidence present: {obsolete}")
    fail("Chainlink direct proxy reads", chainlink_release["directProxyReadsSupported"], True)
    fail(
        "Chainlink underlying aggregator rotation",
        chainlink_release["underlyingAggregatorRotationSupported"],
        True,
    )
    fail(
        "Chainlink maxDelay status",
        chainlink_release["maxDelayStatus"],
        "provisional_reconfirm_before_broadcast",
    )
    for adapter in chainlink_release["adapters"]:
        fail(f"{adapter['role']} provisional maxDelay", adapter["maxDelay"], 93_600)
        fail(f"{adapter['role']} decimals", adapter["feedDecimals"], 8)
    fail(
        "Chainlink adapter mappings",
        [
            (
                adapter["role"],
                adapter["ens"],
                adapter["proxy"].lower(),
                adapter["officialListing"],
                adapter["deviationThresholdBps"],
                adapter["heartbeatSeconds"],
            )
            for adapter in chainlink_release["adapters"]
        ],
        [
            (
                "frxUSD/USD",
                "frxusd-usd.data.eth",
                "0x9b4a96210bc8d9d55b1908b465d8b0de68b7ff83",
                "https://data.chain.link/feeds/ethereum/mainnet/frxusd-usd",
                50,
                86_400,
            ),
            (
                "USDS/USD",
                "usds-usd.data.eth",
                "0xff30586cd0f29ed462364c7e81375fc0c71219b1",
                "https://data.chain.link/feeds/ethereum/mainnet/usds-usd",
                30,
                86_400,
            ),
        ],
    )
    fail(
        "proposal oracle bindings",
        oracle["proposalBindings"],
        [
            {
                "keeper": "frxUSD -> sfrxUSD",
                "targetOracle": "frxUSD/USD Chainlink",
                "downstreamOracle": "frxUSD/USD Chainlink",
            },
            {
                "keeper": "USDC -> sUSDS",
                "targetOracle": "USDC/USDT Curve EMA",
                "downstreamOracle": "USDS/USD Chainlink",
            },
            {
                "keeper": "USDT -> sUSDS",
                "targetOracle": "USDT/USDC Curve EMA",
                "downstreamOracle": "USDS/USD Chainlink",
            },
        ],
    )
    for required_snippet in (
        'frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle")',
        "frxUsdBackingOracle = frxUsdOracle",
        'usdsOracle = vm.parseJsonAddress(json, ".usdsUsdOracle")',
        "_validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY)",
        "_validateChainlinkOracle(usdsOracle, USDS_USD_PROXY)",
        "_validateCurveOracle(usdcOracle, USDC_USDT_ORACLE_POOL, USDC, USDT, true)",
        "_validateCurveOracle(usdtOracle, USDC_USDT_ORACLE_POOL, USDT, USDC, false)",
    ):
        if required_snippet not in proposal_script:
            raise SystemExit(f"selected proposal oracle binding missing: {required_snippet}")

    lowered_deploy_script = deploy_script.lower()
    lowered_proposal_script = proposal_script.lower()
    for required_proxy in (
        "0x9b4a96210bc8d9d55b1908b465d8b0de68b7ff83",
        "0xff30586cd0f29ed462364c7e81375fc0c71219b1",
    ):
        if required_proxy not in lowered_deploy_script or required_proxy not in lowered_proposal_script:
            raise SystemExit(
                f"canonical Chainlink proxy missing from deployer or proposal: {required_proxy}"
            )
    for obsolete_aggregator in (
        "0x62a897c3e81d809c7444bb63d7d51e1f2ebb6c3d",
        "0x592700e4fcdd674dc54d2681ded3b63f54f63f9a",
    ):
        if obsolete_aggregator in lowered_deploy_script or obsolete_aggregator in lowered_proposal_script:
            raise SystemExit(
                f"underlying Chainlink aggregator pinned in deployer or proposal: {obsolete_aggregator}"
            )
    if len(curve_runtime) > EIP_170_LIMIT or len(chainlink_runtime) > EIP_170_LIMIT:
        raise SystemExit("oracle runtime exceeds EIP-170")

    launch = manifest["launchConfiguration"]
    fail("semantic order", launch["semanticCreateOrder"], ["frxUSD -> sfrxUSD", "USDC -> sUSDS", "USDT -> sUSDS"])
    fail("keeper indices", [keeper["index"] for keeper in launch["keepers"]], [1, 2, 3])
    fail(
        "keeper capacities",
        [keeper["maxDeployedCrvUsd"] for keeper in launch["keepers"]],
        ["2500000000000000000000000", "2500000000000000000000000", "5000000000000000000000000"],
    )
    fail("keepers paused", launch["allKeepersStartPaused"], True)
    fail("velocity burst", launch["velocity"]["maxBurstBpsOfMaxDeployed"], 500)
    fail("velocity refill", launch["velocity"]["fullRefillSeconds"], 300)
    fail("velocity shared", launch["velocity"]["sharedAcrossExposureIncreasingPaths"], True)
    fail("velocity contraction refund", launch["velocity"]["contractionRefundsPressure"], False)
    fail(
        "monetary policies",
        [address.lower() for address in launch["monetaryPolicies"]],
        [
            "0x07491d124ddb3ef59a8938fcb3ee50f9fa0b9251",
            "0xc684432fd6322c6d58b6bc5d28b18569aa0ad0a1",
        ],
    )

    config = tomllib.loads((ROOT / "foundry.toml").read_text())
    toolchain = manifest["toolchain"]
    fail("Solidity version", config["profile"]["default"]["solc_version"], toolchain["solidityVersion"])
    fail("EVM version", config["profile"]["default"]["evm_version"], toolchain["evmVersion"])
    fail("Vyper path", config["vyper"]["path"], toolchain["vyperPath"])
    fail("Vyper optimizer", config["vyper"]["optimize"], toolchain["vyperOptimizer"])
    vyper_version = subprocess.run(
        [str(ROOT / toolchain["vyperPath"]), "--version"],
        check=True,
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.strip()
    fail("Vyper version", vyper_version, toolchain["vyperVersion"])
    forge_version = subprocess.run(
        ["forge", "--version"], check=True, cwd=ROOT, capture_output=True, text=True
    ).stdout.splitlines()[0]
    fail("Forge version", forge_version, f"forge Version: {toolchain['forgeVersion']}")

    verification = manifest["verification"]
    fail("listed tests", listed_test_count(), EXPECTED_TESTS)
    fail("manifest tests", verification["testsPassed"], EXPECTED_TESTS)
    fail("manifest failures", verification["testsFailed"], 0)
    fail("manifest skipped", verification["testsSkipped"], 0)
    for label in (
        "keeperAbiParity",
        "factoryAbiParity",
        "previewAbiParity",
        "chainlinkAbiParity",
        "runtimeSizeTest",
        "unifiedDeploymentTest",
        "deploymentJsonTest",
        "curveOracleTests",
        "chainlinkOracleTests",
        "proposalTests",
        "releaseCanary",
        "independentFactoryReview",
        "independentChainlinkReview",
        "independentRefactorReview",
        "independentDeploymentReview",
        "independentCanonicalProxySemanticReview",
        "independentCanonicalProxyIntegrationReview",
        "independentSelectedChainlinkSemanticReview",
        "independentSelectedChainlinkDocumentationReview",
        "manifestMutationTests",
    ):
        fail(label, verification[label], "pass")

    canary = manifest["latestMainnetCanary"]
    fail("canary block", canary["block"], 25_868_730)
    fail("canary script", canary["script"], "script/PegKeeperV3ReleaseCanary.s.sol")
    fail("canary result", canary["result"], "pass")
    fail("canary broadcast", canary["broadcast"], False)
    fail("canary crvUSD sold", canary["simulatedCrvUsdSold"], "100000000000000000000000")
    fail("canary sUSDS received", canary["simulatedSusdsReceived"], "90273364828690285538377")
    fail("canary contraction sUSDS", canary["simulatedContractionQuoteSusds"], "9027336482869028553837")
    fail("canary contraction crvUSD", canary["simulatedContractionQuoteCrvUsd"], "9994594051909217718251")
    fail("canary expansion hash", canary["expansionPathHash"], "0x44f656895137eb8000021497d6f0e888c645e33302d3f669924f2c690722422f")
    fail("canary contraction hash", canary["contractionPathHash"], "0x725f94e6e18aaf43cbc98a5cb47f187661271a0f8d7879a3955ac7817e3ba986")

    operator = manifest["operatorInputs"]
    fail_keys(
        "operator inputs",
        operator,
        {
            "factoryOwner",
            "factoryDefaultsApproved",
            "selectedOracleFamily",
            "chainlinkFrxUsdMaxDelay",
            "chainlinkUsdsMaxDelay",
            "operatorConfirmationRequired",
        },
    )
    fail(
        "factory owner",
        str(operator["factoryOwner"] or "").lower(),
        "0x40907540d8a6c65c637785e8f8b742ae6b0b9968",
    )
    fail(
        "selected oracle family",
        operator["selectedOracleFamily"],
        "chainlink_for_frxusd_usds",
    )
    fail("frxUSD provisional Chainlink delay", operator["chainlinkFrxUsdMaxDelay"], 93_600)
    fail("USDS provisional Chainlink delay", operator["chainlinkUsdsMaxDelay"], 93_600)
    fail("factory defaults unapproved", operator["factoryDefaultsApproved"], False)
    fail("operator confirmation", operator["operatorConfirmationRequired"], True)

    deployment = manifest["deployment"]
    fail_keys(
        "deployment evidence",
        deployment,
        {
            "script",
            "outputPath",
            "environmentConfiguration",
            "monotonicCreateOrder",
            "previewModuleAddress",
            "implementationAddress",
            "factoryAddress",
            "oracleAddresses",
            "keeperAddresses",
            "transactionHashes",
            "verified",
            "registered",
            "activated",
        },
    )
    fail("deployment script", deployment["script"], "script/DeployPegKeeperV3.s.sol")
    fail(
        "deployment output",
        deployment["outputPath"],
        "deployments/mainnet/PegKeeperV3-deployment.json",
    )
    fail("deployment environment configuration", deployment["environmentConfiguration"], False)
    fail("deployment CREATE order", deployment["monotonicCreateOrder"], deployment_fields)
    if (ROOT / deployment["outputPath"]).exists():
        raise SystemExit("undeployed release contains a deployment output")
    for label in ("previewModuleAddress", "implementationAddress", "factoryAddress"):
        fail(f"undeployed {label}", deployment[label], None)
    for label in ("oracleAddresses", "keeperAddresses", "transactionHashes"):
        fail(f"undeployed {label}", deployment[label], [])
    for label in ("verified", "registered", "activated"):
        fail(f"undeployed {label}", deployment[label], False)

    print(
        "PegKeeperV3 Vyper/direct-proxy release manifest verified: "
        f"source={source_commit} tests={EXPECTED_TESTS} "
        f"implementation_runtime={len(impl_runtime) + 32} "
        f"factory_runtime={len(factory_runtime) + 64} "
        f"preview_runtime={len(preview_runtime)} "
        "oracle_selection=chainlink_for_frxusd_usds"
    )


if __name__ == "__main__":
    main()
