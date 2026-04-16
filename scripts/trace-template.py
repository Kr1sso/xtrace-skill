#!/usr/bin/env python3
"""trace-template.py — patch Instruments .tracetemplate files for advanced GPU tracing.

Currently supports:
- Enabling Metal Shader Timeline / shader profiler switches in GPU templates.

This is primarily used by trace-record.sh / xtrace so users can record
shader-timeline capable traces from the command line without manually saving a
custom Instruments template in the GUI first.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import sys
import tempfile
from pathlib import Path
from plistlib import UID
from typing import Any, Iterable, List, Tuple


def _iter_keyed_dicts(objects: List[Any]) -> Iterable[Tuple[int, dict[str, Any], List[Any]]]:
    for idx, obj in enumerate(objects):
        if not isinstance(obj, dict) or "NS.keys" not in obj or "NS.objects" not in obj:
            continue
        try:
            keys = [objects[uid.data] for uid in obj["NS.keys"]]
        except Exception:
            continue
        yield idx, obj, keys


def _set_object_value(objects: List[Any], container: dict[str, Any], value_index: int, new_value: Any) -> bool:
    ref = container["NS.objects"][value_index]
    if isinstance(ref, UID):
        old_value = objects[ref.data]
        if old_value == new_value:
            return False
        objects[ref.data] = new_value
        return True

    if ref == new_value:
        return False
    container["NS.objects"][value_index] = new_value
    return True


def enable_shader_timeline(template_path: str, output_path: str) -> int:
    with open(template_path, "rb") as handle:
        root = plistlib.load(handle)

    if "$objects" not in root or not isinstance(root["$objects"], list):
        raise RuntimeError(f"{template_path} does not look like an Instruments .tracetemplate archive")

    objects: List[Any] = root["$objects"]
    changed = 0
    found = False

    for _idx, container, keys in _iter_keyed_dicts(objects):
        for key_index, key in enumerate(keys):
            if key == "shaderprofiler":
                found = True
                changed += int(_set_object_value(objects, container, key_index, True))
            elif key == "shaderprofilerinternal":
                found = True
                changed += int(_set_object_value(objects, container, key_index, True))

    if not found:
        raise RuntimeError(
            f"Could not find shaderprofiler settings inside template: {template_path}\n"
            "This template may not support Metal Shader Timeline."
        )

    out_parent = os.path.dirname(os.path.abspath(output_path))
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)

    with open(output_path, "wb") as handle:
        plistlib.dump(root, handle, fmt=plistlib.FMT_BINARY)

    return changed


def main() -> int:
    ap = argparse.ArgumentParser(description="Patch Instruments .tracetemplate files")
    sub = ap.add_subparsers(dest="command", required=True)

    p_shader = sub.add_parser(
        "enable-shader-timeline",
        help="Enable Metal Shader Timeline / shader profiler switches in a template",
    )
    p_shader.add_argument("template", help="Input .tracetemplate path")
    p_shader.add_argument("-o", "--output", required=True, help="Output .tracetemplate path")
    p_shader.add_argument("--quiet", action="store_true", help="Suppress progress output")

    args = ap.parse_args()

    if args.command == "enable-shader-timeline":
        changed = enable_shader_timeline(args.template, args.output)
        if not args.quiet:
            print(f"Patched shader timeline settings ({changed} changes): {args.output}")
        return 0

    ap.error(f"Unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
