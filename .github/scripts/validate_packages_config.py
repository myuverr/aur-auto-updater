#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0

"""Filter and re-serialize PACKAGES_CONFIG for nvchecker.

stdin:  raw TOML     → stdout: space-separated package names
argv[1]: output path → cleaned TOML (package tables only)

Filters out [__config__] (auto-generated) and non-table top-level keys.
"""

import re
import sys
import tomllib

_BARE_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _toml_key(key: str) -> str:
    if _BARE_KEY_RE.match(key):
        return key
    return '"' + key.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _toml_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        return f'"{escaped}"'
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        pairs = ", ".join(
            f"{_toml_key(k)} = {_toml_value(v)}" for k, v in value.items()
        )
        return "{" + pairs + "}"
    return str(value)


def _write_packages(packages: dict[str, dict], path: str) -> None:
    with open(path, "w") as fh:
        for name, table in packages.items():
            fh.write(f"[{_toml_key(name)}]\n")
            for key, val in table.items():
                fh.write(f"{_toml_key(key)} = {_toml_value(val)}\n")
            fh.write("\n")


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <outfile>", file=sys.stderr)
        sys.exit(2)

    outfile = sys.argv[1]

    try:
        data = tomllib.loads(sys.stdin.read())
    except tomllib.TOMLDecodeError as exc:
        print(f"::error::PACKAGES_CONFIG is not valid TOML: {exc}", file=sys.stderr)
        sys.exit(1)

    if "__config__" in data:
        print(
            "::warning::PACKAGES_CONFIG contains [__config__]; "
            "ignoring (auto-generated)",
            file=sys.stderr,
        )

    non_table = [k for k, v in data.items() if not isinstance(v, dict)]
    if non_table:
        print(
            "::warning::Ignoring non-table top-level keys in PACKAGES_CONFIG: "
            + ", ".join(non_table),
            file=sys.stderr,
        )

    packages = {
        k: v
        for k, v in data.items()
        if k != "__config__" and isinstance(v, dict)
    }

    if not packages:
        print(
            "::error::PACKAGES_CONFIG contains no package sections",
            file=sys.stderr,
        )
        sys.exit(1)

    _write_packages(packages, outfile)
    print(" ".join(packages))


if __name__ == "__main__":
    main()
