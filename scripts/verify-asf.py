#!/usr/bin/env python3
"""Offline integrity and restricted-canonical-JSON checks. Author: Ted (@haot3x)."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor/asf"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def restricted_json(value):
    # These documents use only ASCII strings and safe integers. Sorting and
    # encoding this subset agrees with JCS; this is not a general JCS encoder.
    if isinstance(value, str):
        value.encode("ascii")
    elif isinstance(value, bool) or value is None:
        pass
    elif isinstance(value, int):
        if abs(value) > 2**53 - 1:
            raise ValueError("Integer outside supported canonical subset")
    elif isinstance(value, list):
        for child in value:
            restricted_json(child)
    elif isinstance(value, dict):
        for key, child in value.items():
            restricted_json(key)
            restricted_json(child)
    else:
        raise ValueError(f"Unsupported canonical value: {value!r}")


def main():
    manifest = (VENDOR / "SHA256SUMS").read_text().splitlines()
    for line in manifest:
        expected, relative = line.split("  ", 1)
        actual = hashlib.sha256((VENDOR / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"Vendored source changed: {relative}")

    documents = {}
    for name in ("specification", "profile", "parameters"):
        path = ROOT / "examples/asf" / f"{name}.json"
        value = json.loads(path.read_text(), object_pairs_hook=unique_object)
        restricted_json(value)
        canonical = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
        if canonical != path.with_name(f"{name}.canonical.json").read_bytes():
            raise ValueError(f"Canonical bytes differ: {name}")
        documents[name] = value

    spec, profile, params = (documents[key] for key in ("specification", "profile", "parameters"))
    if spec["constraints"][0]["parameters"] != params or profile["parameterSchema"]["const"] != params:
        raise ValueError("Specification, profile and parameter document disagree")
    if spec["profiles"]["required"] != [profile["identifier"]]:
        raise ValueError("Required profile does not match descriptor")
    print(f"ASF integrity: {len(manifest)} pinned files; 3 canonical documents; consistent parameters/profile")
    print("Solidity tests separately verify the compiled Keccak-256 document commitments.")


if __name__ == "__main__":
    main()
