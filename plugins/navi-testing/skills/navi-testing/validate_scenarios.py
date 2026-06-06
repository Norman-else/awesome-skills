#!/usr/bin/env python3
"""Validate scenarios.yaml against scenarios.schema.json before a navi-testing run.

Catches the mistakes a Markdown file never could: misspelled agent names, missing
required fields, malformed ids, duplicate ids. Run it before running the skill:

    python3 validate_scenarios.py            # validates ./scenarios.yaml
    python3 validate_scenarios.py path.yaml  # validates a specific file

Exit code 0 = valid, 1 = validation errors, 2 = setup problem (missing deps/files).
Dependencies: PyYAML + jsonschema (both pip-installable).
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def fail_setup(msg: str) -> "None":
    print(f"[setup] {msg}", file=sys.stderr)
    raise SystemExit(2)


try:
    import yaml
except ImportError:
    fail_setup("PyYAML not installed. Run: python3 -m pip install pyyaml jsonschema")

try:
    from jsonschema import Draft7Validator
except ImportError:
    fail_setup("jsonschema not installed. Run: python3 -m pip install jsonschema")


def main() -> int:
    scen_path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "scenarios.yaml"
    schema_path = HERE / "scenarios.schema.json"

    if not scen_path.exists():
        fail_setup(f"scenarios file not found: {scen_path}")
    if not schema_path.exists():
        fail_setup(f"schema not found: {schema_path}")

    try:
        data = yaml.safe_load(scen_path.read_text())
    except yaml.YAMLError as e:
        print(f"[yaml] could not parse {scen_path.name}: {e}", file=sys.stderr)
        return 1

    schema = json.loads(schema_path.read_text())
    validator = Draft7Validator(schema)

    errors = []

    # 1. JSON-Schema structural validation (required fields, agent enum, id format).
    for err in sorted(validator.iter_errors(data), key=lambda e: list(e.path)):
        path = list(err.path)
        where = "/".join(str(p) for p in path) or "(root)"
        # Make the common "bad agent name" error read clearly.
        if err.validator == "enum" and "agents" in path:
            errors.append(f"{where}: unknown agent {err.instance!r} (typo, or a new agent? add it to the schema enum)")
        else:
            errors.append(f"{where}: {err.message}")

    # 2. Cross-scenario checks the schema can't express: duplicate ids, and
    #    in_thread_of must point at a scenario defined EARLIER in the file
    #    (you can only thread under a message that has already been sent — this
    #    also makes dependency cycles impossible by construction).
    if isinstance(data, list):
        seen = {}
        for i, item in enumerate(data):
            if not isinstance(item, dict):
                continue
            sid = item.get("id")
            ref = item.get("in_thread_of")
            # Check the reference against ids seen ABOVE this point (before
            # recording the current id, so a self-reference can't satisfy it).
            if ref is not None:
                if ref == sid:
                    errors.append(f"[{i}] {sid}: in_thread_of references itself")
                elif ref not in seen:
                    errors.append(
                        f"[{i}] {sid}: in_thread_of {ref!r} must reference a scenario "
                        f"defined earlier in the file (no such id above)"
                    )
            if "id" in item:
                if sid in seen:
                    errors.append(f"[{i}]: duplicate id {sid!r} (also at index {seen[sid]})")
                else:
                    seen[sid] = i

    if errors:
        print(f"✗ {scen_path.name}: {len(errors)} problem(s)\n", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        return 1

    n = len(data) if isinstance(data, list) else 0
    print(f"✓ {scen_path.name}: {n} scenario(s) valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
