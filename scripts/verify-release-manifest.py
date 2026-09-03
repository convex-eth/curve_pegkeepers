#!/usr/bin/env python3
"""Fail-closed verification for the undeployed PegKeeperV3 proxy-era release package."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import tomllib
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "deployments/mainnet/PegKeeperV3-release.json"
CHECKLIST_PATH = ROOT / "docs/pegkeeper-v3-release-checklist.md"
EIP_170_LIMIT = 24_576
EIP_3860_LIMIT = 49_152
REFACTORED_IMPLEMENTATION_RUNTIME_BUDGET = 24_450
EXPECTED_TESTS = 298

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
    fail_keys(
        "release manifest",
        manifest,
        {
            "status",
            "generatedAtUtc",
            "repository",
            "productionSourceCommit",
            "productionSourceDiffSha256",
            "toolchain",
            "implementation",
            "previewModule",
            "deploymentFactory",
            "minimalProxy",
            "oraclePolicy",
            "launchConfiguration",
            "verification",
            "latestMainnetCanary",
            "operatorInputs",
            "deployment",
            "activationBlockers",
        },
    )
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
    source_diff_sha256 = manifest["productionSourceDiffSha256"]
    if re.fullmatch(r"[0-9a-f]{64}", source_diff_sha256) is None:
        raise SystemExit(f"invalid production source diff SHA-256: {source_diff_sha256}")
    subprocess.run(
        ["git", "merge-base", "--is-ancestor", source_commit, "HEAD"],
        check=True,
        cwd=ROOT,
    )
    committed_source_diff = subprocess.run(
        ["git", "diff", "--binary", f"{source_commit}^", source_commit],
        check=True,
        cwd=ROOT,
        capture_output=True,
    ).stdout
    fail(
        "production source diff sha256",
        hashlib.sha256(committed_source_diff).hexdigest(),
        source_diff_sha256,
    )
    required_evidence_drift = {
        "deployments/mainnet/PegKeeperV3-release.json",
        "docs/pegkeeper-v3-release-checklist.md",
    }
    allowed_evidence_drift = required_evidence_drift | {
        "scripts/verify-release-manifest.py",
    }
    actual_drift = set(
        subprocess.run(
            ["git", "diff", "--name-only", source_commit, "--"],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
    )
    if not required_evidence_drift.issubset(actual_drift) or not actual_drift.issubset(
        allowed_evidence_drift
    ):
        raise SystemExit(
            "tracked drift from production source commit: "
            f"required {sorted(required_evidence_drift)}, "
            f"allowed {sorted(allowed_evidence_drift)}, got {sorted(actual_drift)}"
        )

    checklist = CHECKLIST_PATH.read_text()
    checklist_source_commits = re.findall(
        r"^- \[x\] Production source commit: `([0-9a-f]{40})`\.$",
        checklist,
        flags=re.MULTILINE,
    )
    fail("checklist production source commit", checklist_source_commits, [source_commit])
    checklist_source_diffs = re.findall(
        r"^- \[x\] Exact pre-commit staged source diff SHA-256: `([0-9a-f]{64})`\.$",
        checklist,
        flags=re.MULTILINE,
    )
    fail("checklist production source diff", checklist_source_diffs, [source_diff_sha256])
    checklist_source_hashes = re.findall(
        r"^- \[x\] Source SHA-256: `([0-9a-f]{64})`\.$",
        checklist,
        flags=re.MULTILINE,
    )
    expected_checklist_source_hashes = [
        manifest["implementation"]["source"]["sha256"],
        manifest["previewModule"]["source"]["sha256"],
        manifest["deploymentFactory"]["source"]["sha256"],
    ]
    fail(
        "checklist source hashes",
        checklist_source_hashes,
        expected_checklist_source_hashes,
    )
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
        "usdcFraxNetDeposit",
        "usdtFraxNetDeposit",
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
    for required_snippet in (
        "prepareFraxNetAccounts(deployment)",
        "factory.createFraxNetDeposit(ETHEREUM_LAYERZERO_EID, recipient, bytes32(0))",
        "factory.isFraxNetDeposit(account)",
    ):
        if required_snippet not in deploy_script:
            raise SystemExit(f"FraxNet deployment wiring missing: {required_snippet}")
    for required_snippet in (
        "_validateFraxNetAccount(usdcFraxNetDeposit, usdcKeeper)",
        "_validateFraxNetAccount(usdtFraxNetDeposit, usdtKeeper)",
        "factory.isFraxNetDeposit(account)",
        "deposit.targetAddress() == bytes32(uint256(uint160(keeper)))",
    ):
        if required_snippet not in proposal_script:
            raise SystemExit(f"FraxNet proposal wiring missing: {required_snippet}")
    implementation_source = ARTIFACTS["implementation"][0].read_text()
    for required_snippet in (
        "FraxNetDeposit(_step.venue).factory() == FRAXNET_DEPOSIT_FACTORY",
        "FraxNetDepositFactory(FRAXNET_DEPOSIT_FACTORY).isFraxNetDeposit(_step.venue)",
        "FraxNetDeposit(_step.venue).targetAddress() == convert(self, bytes32)",
        "token_in.transfer(_step.venue, _amount_in)",
        "FraxNetDeposit(_step.venue).processRedemption(_amount_in)",
    ):
        if required_snippet not in implementation_source:
            raise SystemExit(f"FraxNet implementation wiring missing: {required_snippet}")
    obsolete_deployment_fields = (
        "frxUsdTargetOracle",
        "sfrxUsdBackingOracle",
        "susdsBackingOracle",
        "frxUsdChainlinkOracle",
        "usdsChainlinkOracle",
        "usdsUsdOracle",
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
        "selected_chainlink_for_frxusd",
    )
    fail("oracle selection blocker", oracle["releaseBlockedUntilSelection"], False)
    fail("oracle precision", oracle["commonPriceDecimals"], 18)
    fail("oracle par cap", oracle["favorablePriceCap"], "1000000000000000000")
    fail("oracle floor", oracle["minimumLaunchPrice"], "999700000000000000")
    fail("Curve adapter count", len(oracle["curve"]["adapters"]), 2)
    fail("Chainlink adapter count", len(oracle["chainlink"]["adapters"]), 1)
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
        ],
    )
    fail(
        "proposal oracle bindings",
        oracle["proposalBindings"],
        [
            {
                "keeper": "frxUSD -> frxUSD",
                "targetOracle": "frxUSD/USD Chainlink",
                "downstreamOracle": "frxUSD/USD Chainlink",
            },
            {
                "keeper": "USDC -> frxUSD",
                "targetOracle": "USDC/USDT Curve EMA",
                "downstreamOracle": "frxUSD/USD Chainlink",
            },
            {
                "keeper": "USDT -> frxUSD",
                "targetOracle": "USDT/USDC Curve EMA",
                "downstreamOracle": "frxUSD/USD Chainlink",
            },
        ],
    )
    for required_snippet in (
        'frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle")',
        "frxUsdBackingOracle = frxUsdOracle",
        "_validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY)",
        "_validateCurveOracle(usdcOracle, USDC_USDT_ORACLE_POOL, USDC, USDT, true)",
        "_validateCurveOracle(usdtOracle, USDC_USDT_ORACLE_POOL, USDT, USDC, false)",
    ):
        if required_snippet not in proposal_script:
            raise SystemExit(f"selected proposal oracle binding missing: {required_snippet}")

    lowered_deploy_script = deploy_script.lower()
    lowered_proposal_script = proposal_script.lower()
    for required_proxy in (
        "0x9b4a96210bc8d9d55b1908b465d8b0de68b7ff83",
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
    fail_keys(
        "launch configuration",
        launch,
        {
            "semanticCreateOrder",
            "keepers",
            "allKeepersStartPaused",
            "velocity",
            "monetaryPolicies",
            "executionPolicy",
        },
    )
    fail(
        "semantic order",
        launch["semanticCreateOrder"],
        ["frxUSD -> frxUSD", "USDC -> frxUSD", "USDT -> frxUSD"],
    )
    for index, keeper in enumerate(launch["keepers"]):
        fail_keys(
            f"launch keeper {index}",
            keeper,
            {
                "index",
                "name",
                "route",
                "finalToken",
                "endpointMode",
                "expansionPath",
                "contractionPath",
                "maxDeployedCrvUsd",
            },
        )
    fail("keeper indices", [keeper["index"] for keeper in launch["keepers"]], [1, 2, 3])
    fail(
        "keeper routes",
        [keeper["route"] for keeper in launch["keepers"]],
        ["frxUSD -> frxUSD", "USDC -> frxUSD", "USDT -> frxUSD"],
    )
    fail(
        "keeper final tokens",
        [keeper["finalToken"] for keeper in launch["keepers"]],
        ["frxUSD", "frxUSD", "frxUSD"],
    )
    fail(
        "keeper endpoint modes",
        [keeper["endpointMode"] for keeper in launch["keepers"]],
        ["vanilla_erc20", "vanilla_erc20", "vanilla_erc20"],
    )
    fail(
        "keeper expansion paths",
        [keeper["expansionPath"] for keeper in launch["keepers"]],
        ["empty", "FRXUSD_MINT", "CURVE_USDT_TO_USDC -> FRXUSD_MINT"],
    )
    fail(
        "keeper contraction paths",
        [keeper["contractionPath"] for keeper in launch["keepers"]],
        [
            "CURVE_FRXUSD_TO_CRVUSD",
            "FRAXNET_REDEEM -> CURVE_USDC_TO_CRVUSD",
            "FRAXNET_REDEEM -> CURVE_USDC_TO_USDT -> CURVE_USDT_TO_CRVUSD",
        ],
    )
    fail(
        "keeper capacities",
        [keeper["maxDeployedCrvUsd"] for keeper in launch["keepers"]],
        ["2500000000000000000000000", "2500000000000000000000000", "5000000000000000000000000"],
    )
    fail("keepers paused", launch["allKeepersStartPaused"], True)
    execution_policy = launch["executionPolicy"]
    fail_keys(
        "execution policy",
        execution_policy,
        {
            "curveSwapBps",
            "targetAmmBps",
            "erc4626DepositBps",
            "erc4626RedeemBps",
            "frxUsdMintBps",
            "fraxNetRedeemBps",
            "daiUsdsConverterBps",
            "downstreamAndYieldToTargetRouteLossBps",
            "monetaryContractionRouteLossAllowanceBps",
            "monetaryContractionUsesPositiveProfitFloor",
            "normalExitProfitFloorPpm",
            "earlyExitProfitFloorPpm",
            "intermediateErc4626StepsAllowed",
            "erc4626StepValuation",
            "finalEndpointModesSupported",
        },
    )
    fail("Curve execution tolerance", execution_policy["curveSwapBps"], 3)
    fail("target-AMM Curve execution tolerance", execution_policy["targetAmmBps"], 3)
    fail("ERC-4626 deposit execution tolerance", execution_policy["erc4626DepositBps"], 1)
    fail("ERC-4626 redeem execution tolerance", execution_policy["erc4626RedeemBps"], 1)
    fail("frxUSD mint execution tolerance", execution_policy["frxUsdMintBps"], 1)
    fail("FraxNet redeem execution tolerance", execution_policy["fraxNetRedeemBps"], 2)
    fail("DaiUsds execution tolerance", execution_policy["daiUsdsConverterBps"], 0)
    fail(
        "downstream and yield-to-target route tolerance",
        execution_policy["downstreamAndYieldToTargetRouteLossBps"],
        5,
    )
    fail(
        "contraction general route-loss allowance",
        execution_policy["monetaryContractionRouteLossAllowanceBps"],
        None,
    )
    fail(
        "contraction positive exit-profit floor",
        execution_policy["monetaryContractionUsesPositiveProfitFloor"],
        True,
    )
    fail("normal exit-profit floor", execution_policy["normalExitProfitFloorPpm"], 1_000)
    fail("early exit-profit floor", execution_policy["earlyExitProfitFloorPpm"], 5_000)
    fail("intermediate ERC-4626 steps", execution_policy["intermediateErc4626StepsAllowed"], True)
    fail(
        "ERC-4626 step valuation",
        execution_policy["erc4626StepValuation"],
        "action_local_share_delta_convertToAssets",
    )
    fail(
        "final endpoint modes",
        execution_policy["finalEndpointModesSupported"],
        ["vanilla_erc20", "erc4626"],
    )
    fail_keys(
        "velocity configuration",
        launch["velocity"],
        {
            "maxBurstBpsOfMaxDeployed",
            "fullRefillSeconds",
            "sharedAcrossExposureIncreasingPaths",
            "contractionRefundsPressure",
        },
    )
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
    fail_keys(
        "verification evidence",
        verification,
        {
            "testsPassed",
            "testsFailed",
            "testsSkipped",
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
            "independentPreviewParityReview",
            "independentCanonicalProxySemanticReview",
            "independentCanonicalProxyIntegrationReview",
            "independentSelectedChainlinkSemanticReview",
            "independentSelectedChainlinkDocumentationReview",
            "manifestMutationTests",
            "independentCurrentNatSpecReview",
            "independentCurrentSourceSecurityReview",
            "independentCurrentLaunchPolicyReview",
            "independentCurrentSourcePackageReview",
        },
    )
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
        "independentPreviewParityReview",
        "independentCanonicalProxySemanticReview",
        "independentCanonicalProxyIntegrationReview",
        "independentSelectedChainlinkSemanticReview",
        "independentSelectedChainlinkDocumentationReview",
        "manifestMutationTests",
        "independentCurrentNatSpecReview",
        "independentCurrentSourceSecurityReview",
        "independentCurrentLaunchPolicyReview",
        "independentCurrentSourcePackageReview",
    ):
        fail(label, verification[label], "pass")

    canary = manifest["latestMainnetCanary"]
    fail_keys(
        "pinned canary evidence",
        canary,
        {
            "block",
            "script",
            "result",
            "simulatedCrvUsdSold",
            "simulatedFrxUsdReceived",
            "simulatedContractionQuoteFrxUsd",
            "simulatedContractionQuoteCrvUsd",
            "simulatedContractionReceivedCrvUsd",
            "rwaRouteExercised",
            "fraxNetAccountCloneRequiredForShanghai",
            "superstateTokenHarnessRequiredForShanghai",
            "expansionPathHash",
            "contractionPathHash",
            "broadcast",
        },
    )
    fail("canary block", canary["block"], 25_868_730)
    fail("canary script", canary["script"], "script/PegKeeperV3ReleaseCanary.s.sol")
    fail("canary result", canary["result"], "pass")
    fail("canary broadcast", canary["broadcast"], False)
    fail("canary crvUSD sold", canary["simulatedCrvUsdSold"], "100000000000000000000000")
    fail("canary frxUSD received", canary["simulatedFrxUsdReceived"], "100016620117244135933000")
    fail("canary contraction frxUSD", canary["simulatedContractionQuoteFrxUsd"], "10001662011724413593300")
    fail("canary contraction quote crvUSD", canary["simulatedContractionQuoteCrvUsd"], "10031479301488711916782")
    fail("canary contraction received crvUSD", canary["simulatedContractionReceivedCrvUsd"], "10030476151557962947554")
    fail("canary RWA route", canary["rwaRouteExercised"], True)
    fail("canary FraxNet account clone disclosure", canary["fraxNetAccountCloneRequiredForShanghai"], True)
    fail("canary USTB harness disclosure", canary["superstateTokenHarnessRequiredForShanghai"], True)
    fail("canary expansion hash", canary["expansionPathHash"], "0x17600eb74b28066eb62f0c63fd46e6e6352fd34efb7b7c8415971240b25e7f9d")
    fail("canary contraction hash", canary["contractionPathHash"], "0x1602a97a9de217a466169f46195f2ac971329883350aea19826b7a2a97c2ef9c")

    operator = manifest["operatorInputs"]
    fail_keys(
        "operator inputs",
        operator,
        {
            "factoryOwner",
            "factoryDefaultsApproved",
            "selectedOracleFamily",
            "chainlinkFrxUsdMaxDelay",
            "fraxRedemptionActivationApproved",
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
        "chainlink_for_frxusd",
    )
    fail("frxUSD provisional Chainlink delay", operator["chainlinkFrxUsdMaxDelay"], 93_600)
    fail(
        "Frax redemption activation unapproved",
        operator["fraxRedemptionActivationApproved"],
        False,
    )
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
            "fraxNetFactory",
            "previewModuleAddress",
            "implementationAddress",
            "factoryAddress",
            "oracleAddresses",
            "fraxNetAccountAddresses",
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
    fail(
        "deployment FraxNet factory",
        deployment["fraxNetFactory"].lower(),
        "0xa3d62f83c433e2a56af392e08a705a52ded63696",
    )
    if (ROOT / deployment["outputPath"]).exists():
        raise SystemExit("undeployed release contains a deployment output")
    for label in ("previewModuleAddress", "implementationAddress", "factoryAddress"):
        fail(f"undeployed {label}", deployment[label], None)
    for label in (
        "oracleAddresses",
        "fraxNetAccountAddresses",
        "keeperAddresses",
        "transactionHashes",
    ):
        fail(f"undeployed {label}", deployment[label], [])
    for label in ("verified", "registered", "activated"):
        fail(f"undeployed {label}", deployment[label], False)

    fail(
        "activation blockers",
        manifest["activationBlockers"],
        [
            "Governance must independently reconfirm the canonical frxUSD/USD Chainlink proxy, 8-decimal metadata, live positive completed round, and provisional 93,600-second maxDelay.",
            "Governance must confirm the independent USDC and USDT Curve EMA target-health checks, including pool code, coin order, oracle behavior, and inversion.",
            "Before enabling a FraxNet redemption route, governance must reconfirm the mint custodian, FraxNet factory/account identities, account recipients, beacon implementation, pause state, configured RWA redeemer, fees, limits, and authorization.",
            "Governance must measure direct atomic USDC and atomically reachable RWA-route USDC separately, exclude raw downstream balances and delayed settlement, and execute bounded canaries through both redemption branches.",
            "Governance must confirm the hardcoded Curve Ownership Agent factory owner, all shared defaults, and all candidate addresses.",
            "A fresh current-block canary and every release gate must pass from the production source commit before broadcast.",
            "Deployment, registration, debt-ceiling, policy, and activation transactions require explicit authorization; this package broadcasts none.",
        ],
    )

    print(
        "PegKeeperV3 Vyper/direct-proxy release manifest verified: "
        f"source={source_commit} tests={EXPECTED_TESTS} "
        f"implementation_runtime={len(impl_runtime) + 32} "
        f"factory_runtime={len(factory_runtime) + 64} "
        f"preview_runtime={len(preview_runtime)} "
        "oracle_selection=chainlink_for_frxusd"
    )


if __name__ == "__main__":
    main()
