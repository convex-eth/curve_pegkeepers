#!/usr/bin/env python3
"""Reject explicit Vyper default/fallback handlers in project source."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VYPER_SOURCE = ROOT / "src"
DEFAULT_DEFINITION = re.compile(r"^\s*def\s+__default__\s*\(", re.MULTILINE)


def main() -> int:
    violations: list[str] = []
    for path in sorted(VYPER_SOURCE.rglob("*.vy")):
        source = path.read_text(encoding="utf-8")
        for match in DEFAULT_DEFINITION.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            violations.append(f"{path.relative_to(ROOT)}:{line}: explicit __default__ handler")

    if violations:
        raise SystemExit("\n".join(violations))

    print("No explicit Vyper default handlers found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
