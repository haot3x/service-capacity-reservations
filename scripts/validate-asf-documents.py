#!/usr/bin/env python3
"""Run with: uv run --with jsonschema==4.26.0 python scripts/validate-asf-documents.py"""
import json
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[1]
schemas = {
    path.name: json.loads(path.read_text())
    for path in (ROOT / "vendor/asf/schemas").glob("*.json")
}
# All schema references resolve locally; no schema download is needed.
registry = Registry().with_resources(
    (schema["$id"], Resource.from_contents(schema)) for schema in schemas.values()
)
for filename, schema_name in (
    ("specification", "safety-specification.schema.json"),
    ("profile", "profile-descriptor.schema.json"),
):
    document = json.loads((ROOT / "examples/asf" / f"{filename}.json").read_text())
    Draft202012Validator(schemas[schema_name], registry=registry).validate(document)
    print(f"{filename}.json passes pinned upstream {schema_name}")
