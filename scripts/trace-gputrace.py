#!/usr/bin/env python3
"""
trace-gputrace.py — Inspect and summarize MTLCaptureManager .gputrace bundles.

The .gputrace format is not publicly documented, so this tool focuses on the
parts we can reliably extract from the bundle itself:
  - capture metadata (binary plist)
  - bundle file inventory and sizes
  - resource snapshot files (MTLBuffer-* / MTLTexture-*)
  - resource labels and shader/library names recovered from device-resources*
  - optional decoding of raw buffer snapshots with flexible layouts
  - optional HTML reports for browser-friendly inspection

Examples:
    python3 scripts/trace-gputrace.py info capture.gputrace
    python3 scripts/trace-gputrace.py resources capture.gputrace
    python3 scripts/trace-gputrace.py buffer capture.gputrace --buffer "Compute Values Buffer" --layout float
    python3 scripts/trace-gputrace.py buffer capture.gputrace --buffer "Window Vertices" --layout "float2,float4" --index 0-5
    python3 scripts/trace-gputrace.py report capture.gputrace -o capture_report.html
"""

from __future__ import annotations

import argparse
import html
import json
import os
import plistlib
import re
import struct
import sys
from pathlib import Path
from statistics import mean
from typing import Any, Iterable

RESOURCE_RE = re.compile(r"^MTL(Buffer|Texture)-\d+-\d+(?:-[A-Za-z0-9]+)*$")
RESOURCE_ID_RE = re.compile(r"^(MTL(?:Buffer|Texture)-\d+-\d+)")
SURFACE_RE = re.compile(r"^CAMetalLayer-\d+-index-\d+$")
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{2,}$")

STRING_BLACKLIST = {
    "buffer",
    "buffers",
    "capture",
    "command",
    "commands",
    "compute",
    "descriptor",
    "device",
    "event",
    "fragment",
    "function",
    "functions",
    "gpu",
    "image",
    "images",
    "library",
    "libraries",
    "main",
    "metal",
    "object",
    "objects",
    "pipeline",
    "pipeline-libraries",
    "process",
    "program_source",
    "resource",
    "resources",
    "shader",
    "shaders",
    "string",
    "strings",
    "texture",
    "textures",
    "thread",
    "vertex",
}

SECTION_BREAKERS = {
    "buffers",
    "textures",
    "heaps",
    "tensors",
    "compilers",
    "libraries",
    "pipeline-libraries",
    "fences",
    "events",
    "late-eval-events",
    "shared-events",
    "render-pipeline-states",
    "compute-pipeline-states",
    "function-handles",
    "visible-function-tables",
    "intersection-function-tables",
    "program_source",
}


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def ensure_bundle(path: str) -> Path:
    bundle = Path(path)
    if not bundle.is_dir():
        fail(f"Not a directory: {path}")
    return bundle


def sanitize_json(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): sanitize_json(v) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize_json(v) for v in value]
    if isinstance(value, tuple):
        return [sanitize_json(v) for v in value]
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, Path):
        return str(value)
    return value


def load_metadata(bundle: Path) -> dict[str, Any]:
    metadata_path = bundle / "metadata"
    if not metadata_path.exists():
        return {}
    try:
        with metadata_path.open("rb") as fh:
            return sanitize_json(plistlib.load(fh))
    except Exception:
        return {}


def read_prefix(path: Path, byte_count: int = 16) -> bytes:
    try:
        with path.open("rb") as fh:
            return fh.read(byte_count)
    except OSError:
        return b""


def classify_file(path: Path) -> tuple[str, str]:
    prefix = read_prefix(path)
    if prefix.startswith(b"bplist00"):
        return "binary_plist", prefix[:8].decode("ascii", "ignore")
    if prefix.startswith(b"MTSP"):
        return "mtsp_binary", prefix[:8].hex()
    if prefix.startswith(b"<?xml"):
        return "xml", prefix[:8].decode("ascii", "ignore")
    if prefix.startswith(b"{\n") or prefix.startswith(b"{") or prefix.startswith(b"[\n") or prefix.startswith(b"["):
        return "json_or_text", prefix[:8].decode("ascii", "ignore")
    if prefix[:2] in (b"\x78\x01", b"\x78\x5e", b"\x78\x9c", b"\x78\xda"):
        return "zlib_stream", prefix[:4].hex()
    if prefix and all(32 <= b <= 126 or b in (9, 10, 13) for b in prefix):
        return "text", prefix[:8].decode("ascii", "ignore")
    return "binary", prefix[:8].hex()


def list_bundle_files(bundle: Path) -> list[dict[str, Any]]:
    files: list[dict[str, Any]] = []
    for root, _, names in os.walk(bundle):
        for name in sorted(names):
            full_path = Path(root) / name
            rel_path = full_path.relative_to(bundle)
            kind, magic = classify_file(full_path)
            files.append(
                {
                    "path": str(rel_path),
                    "size_bytes": full_path.stat().st_size,
                    "kind": kind,
                    "magic": magic,
                }
            )
    files.sort(key=lambda entry: entry["path"])
    return files


def extract_printable_strings(data: bytes, min_len: int = 4) -> list[dict[str, Any]]:
    strings: list[dict[str, Any]] = []
    current: list[str] = []
    start = None
    for index, byte in enumerate(data):
        if 32 <= byte <= 126:
            if start is None:
                start = index
            current.append(chr(byte))
        else:
            if start is not None and len(current) >= min_len:
                strings.append({"offset": start, "value": "".join(current)})
            current = []
            start = None
    if start is not None and len(current) >= min_len:
        strings.append({"offset": start, "value": "".join(current)})
    return strings


def is_label_candidate(value: str) -> bool:
    stripped = value.strip()
    if len(stripped) < 3 or len(stripped) > 128:
        return False
    if stripped.startswith("/") or stripped.startswith("./"):
        return False
    if stripped.startswith("MTL"):
        return False
    if stripped.endswith(".metallib") or stripped.endswith(".metal"):
        return False
    if re.fullmatch(r"[A-F0-9-]{16,}", stripped):
        return False
    lower = stripped.lower()
    if lower in STRING_BLACKLIST:
        return False
    if stripped.startswith("com.apple."):
        return False
    return True


def is_probable_function_name(value: str) -> bool:
    lower = value.lower()
    if not IDENTIFIER_RE.match(value):
        return False
    if lower in STRING_BLACKLIST or lower in SECTION_BREAKERS:
        return False
    if len(value) < 8 and "_" not in value:
        return False
    if value.startswith("C") and re.fullmatch(r"C[iuSlwbt]+", value):
        return False
    return any(char.islower() for char in value)


def score_label_candidate(candidate: str) -> int:
    score = 0
    lower = candidate.lower()
    if " " in candidate:
        score += 4
    if "." in candidate or "-" in candidate or ":" in candidate:
        score += 2
    if any(ch.isupper() for ch in candidate):
        score += 1
    if len(candidate) <= 48:
        score += 1
    if any(token in lower for token in ("buffer", "texture", "drawable", "vertex", "vertices", "uniform")):
        score += 3
    if "frame" in lower:
        score -= 1
    return score


def extract_bundle_strings(bundle: Path) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for path in sorted(bundle.iterdir()):
        if not path.is_file():
            continue
        if path.name == "metadata":
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        strings = extract_printable_strings(data)
        if strings:
            result[path.name] = strings
    return result


def is_resource_snapshot_name(name: str) -> bool:
    return bool(RESOURCE_RE.match(name) or SURFACE_RE.match(name))


def canonical_resource_name(name: str) -> str:
    if SURFACE_RE.match(name):
        return name
    match = RESOURCE_ID_RE.match(name)
    return match.group(1) if match else name


def build_label_map(bundle: Path, actual_resources: set[str]) -> dict[str, str]:
    label_map: dict[str, str] = {}
    candidate_files = [
        path for path in sorted(bundle.iterdir())
        if path.is_file() and path.name != "metadata" and not is_resource_snapshot_name(path.name)
    ]
    # Prefer device-resources files first because their record layout is the most reliable.
    candidate_files.sort(key=lambda path: (0 if path.name.startswith("device-resources") else 1, path.name))

    for path in candidate_files:
        strings = extract_printable_strings(path.read_bytes())
        resource_positions = [
            (entry["offset"], canonical_resource_name(entry["value"]))
            for entry in strings
            if is_resource_snapshot_name(entry["value"]) and canonical_resource_name(entry["value"]) in actual_resources
        ]
        label_candidates = [
            (entry["offset"], entry["value"])
            for entry in strings
            if is_label_candidate(entry["value"])
        ]
        forward_only = path.name.startswith("device-resources") or path.name.startswith("delta-device-resources")
        for resource_offset, resource_name in resource_positions:
            if resource_name in label_map:
                continue
            best_label = None
            best_distance = None
            best_score = -1
            for label_offset, candidate in label_candidates:
                distance = label_offset - resource_offset if forward_only else abs(label_offset - resource_offset)
                if forward_only and distance <= 0:
                    continue
                if abs(distance) > 4096:
                    continue
                score = score_label_candidate(candidate)
                if best_label is None:
                    best_label = candidate
                    best_distance = abs(distance)
                    best_score = score
                    continue
                assert best_distance is not None
                if score > best_score or (score == best_score and abs(distance) < best_distance):
                    best_label = candidate
                    best_distance = abs(distance)
                    best_score = score
            if best_label:
                label_map[resource_name] = best_label
    return label_map


def extract_shader_inventory(bundle_strings: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    libraries: list[str] = []
    candidate_functions: set[str] = set()

    for file_name, strings in bundle_strings.items():
        if not file_name.startswith("device-resources") and not file_name.startswith("delta-device-resources"):
            continue
        values = [entry["value"] for entry in strings]
        for index, value in enumerate(values):
            if value.endswith(".metallib"):
                libraries.append(value)
                for follow in values[index + 1:index + 64]:
                    if follow == "pipeline-libraries" or follow.endswith(".metallib"):
                        break
                    if is_probable_function_name(follow):
                        candidate_functions.add(follow)
            if value in {"function", "functions"}:
                for follow in values[index + 1:index + 24]:
                    lower_follow = follow.lower()
                    if lower_follow in SECTION_BREAKERS:
                        break
                    if follow.endswith(".metallib"):
                        break
                    if is_probable_function_name(follow):
                        candidate_functions.add(follow)
                        break

    return {
        "libraries": sorted(set(libraries)),
        "functions": sorted(candidate_functions),
    }


def extract_embedded_label(path: Path) -> str | None:
    try:
        strings = extract_printable_strings(path.read_bytes()[:4096])
    except OSError:
        return None
    best_label = None
    best_score = -1
    for entry in strings:
        candidate = entry["value"]
        if candidate == path.name or not is_label_candidate(candidate):
            continue
        score = score_label_candidate(candidate)
        if score > best_score:
            best_label = candidate
            best_score = score
    return best_label


def parse_resources(bundle: Path, bundle_strings: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    resource_files = [path for path in sorted(bundle.iterdir()) if path.is_file() and is_resource_snapshot_name(path.name)]
    actual_resource_names = {canonical_resource_name(path.name) for path in resource_files}
    label_map = build_label_map(bundle, actual_resource_names)

    resources: list[dict[str, Any]] = []
    for path in resource_files:
        if path.name.startswith("MTLBuffer"):
            resource_type = "buffer"
        elif path.name.startswith("MTLTexture"):
            resource_type = "texture"
        else:
            resource_type = "surface"
        label = label_map.get(canonical_resource_name(path.name))
        if label is None and resource_type == "surface":
            label = extract_embedded_label(path)
        resources.append(
            {
                "name": path.name,
                "type": resource_type,
                "size_bytes": path.stat().st_size,
                "label": label,
            }
        )

    shader_inventory = extract_shader_inventory(bundle_strings)
    return {
        "resources": resources,
        "label_map": label_map,
        "buffer_count": sum(1 for entry in resources if entry["type"] == "buffer"),
        "texture_count": sum(1 for entry in resources if entry["type"] == "texture"),
        "surface_count": sum(1 for entry in resources if entry["type"] == "surface"),
        "shader_inventory": shader_inventory,
    }


def build_overview(bundle: Path) -> dict[str, Any]:
    metadata = load_metadata(bundle)
    files = list_bundle_files(bundle)
    bundle_strings = extract_bundle_strings(bundle)
    resource_data = parse_resources(bundle, bundle_strings)

    total_size = sum(entry["size_bytes"] for entry in files)
    metadata_summary = {
        "uuid": metadata.get("(uuid)"),
        "captured_frames_count": metadata.get("DYCaptureEngine.captured_frames_count"),
        "graphics_api": {1: "Metal"}.get(metadata.get("DYCaptureSession.graphics_api"), metadata.get("DYCaptureSession.graphics_api")),
    }

    return {
        "path": str(bundle),
        "metadata": metadata,
        "metadata_summary": metadata_summary,
        "bundle": {
            "file_count": len(files),
            "total_size_bytes": total_size,
            "files": files,
        },
        "resources": resource_data,
        "strings": {
            name: entries[:256] for name, entries in bundle_strings.items()
        },
    }


def format_bytes(size: int) -> str:
    units = ["B", "KB", "MB", "GB"]
    value = float(size)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1024.0
    return f"{size}B"


LAYOUT_COMPONENTS = {
    "float": ("f", 1),
    "float2": ("ff", 2),
    "float3": ("fff", 3),
    "float4": ("ffff", 4),
    "half": ("e", 1),
    "half2": ("ee", 2),
    "half4": ("eeee", 4),
    "uint8": ("B", 1),
    "uchar4": ("BBBB", 4),
    "int32": ("i", 1),
    "uint16": ("H", 1),
    "uint32": ("I", 1),
}


def resolve_resource_name(overview: dict[str, Any], name_or_label: str) -> str:
    resources = overview["resources"]["resources"]
    lower_query = name_or_label.lower()
    for entry in resources:
        if entry["name"].lower() == lower_query:
            return entry["name"]
    for entry in resources:
        label = entry.get("label") or ""
        if label.lower() == lower_query:
            return entry["name"]
    for entry in resources:
        label = entry.get("label") or ""
        if lower_query in label.lower():
            return entry["name"]
    fail(f"Resource not found: {name_or_label}")
    return ""


def parse_layout(layout: str) -> tuple[str, list[tuple[str, int]]]:
    fmt_parts = ["<"]
    components: list[tuple[str, int]] = []
    for raw_component in layout.split(","):
        component = raw_component.strip()
        if component not in LAYOUT_COMPONENTS:
            fail(f"Unsupported layout component: {component}")
        fmt, width = LAYOUT_COMPONENTS[component]
        fmt_parts.append(fmt)
        components.append((component, width))
    return "".join(fmt_parts), components


def decode_row(values: tuple[Any, ...], components: list[tuple[str, int]]) -> list[Any]:
    decoded: list[Any] = []
    index = 0
    for _, width in components:
        if width == 1:
            decoded.append(values[index])
        else:
            decoded.append(list(values[index:index + width]))
        index += width
    return decoded


def stats_for_rows(rows: list[list[Any]]) -> list[dict[str, Any]]:
    stats: list[dict[str, Any]] = []
    if not rows:
        return stats

    width = len(rows[0])
    for column_index in range(width):
        scalars: list[float] = []
        for row in rows:
            value = row[column_index]
            if isinstance(value, list):
                scalars.extend(float(item) for item in value)
            else:
                scalars.append(float(value))
        if not scalars:
            continue
        stats.append(
            {
                "field": column_index,
                "min": min(scalars),
                "max": max(scalars),
                "mean": mean(scalars),
            }
        )
    return stats


def parse_index_range(spec: str) -> tuple[int, int]:
    if "-" in spec:
        start_text, end_text = spec.split("-", 1)
        start = int(start_text)
        end = int(end_text)
        if end < start:
            fail(f"Invalid index range: {spec}")
        return start, end - start + 1
    value = int(spec)
    return value, 1


def load_buffer_rows(bundle: Path, overview: dict[str, Any], name_or_label: str, layout: str, index_spec: str) -> dict[str, Any]:
    resource_name = resolve_resource_name(overview, name_or_label)
    resource_path = bundle / resource_name
    fmt, components = parse_layout(layout)
    stride = struct.calcsize(fmt)
    raw = resource_path.read_bytes()
    total_rows = len(raw) // stride
    start, count = parse_index_range(index_spec)
    end = min(total_rows, start + count)

    decoded_rows: list[dict[str, Any]] = []
    raw_rows: list[list[Any]] = []
    for row_index in range(start, end):
        offset = row_index * stride
        values = struct.unpack_from(fmt, raw, offset)
        decoded = decode_row(values, components)
        raw_rows.append(decoded)
        decoded_rows.append({"index": row_index, "fields": decoded})

    label = overview["resources"]["label_map"].get(resource_name)
    return {
        "resource": resource_name,
        "label": label,
        "layout": layout,
        "stride_bytes": stride,
        "total_rows": total_rows,
        "rows": decoded_rows,
        "stats": stats_for_rows(raw_rows),
    }


def render_info_text(overview: dict[str, Any]) -> str:
    lines = []
    lines.append(f"GPU Trace: {overview['path']}")
    summary = overview["metadata_summary"]
    if summary.get("uuid"):
        lines.append(f"  UUID: {summary['uuid']}")
    if summary.get("graphics_api") is not None:
        lines.append(f"  API: {summary['graphics_api']}")
    if summary.get("captured_frames_count") is not None:
        lines.append(f"  Captured frames: {summary['captured_frames_count']}")
    lines.append(f"  Files: {overview['bundle']['file_count']} ({format_bytes(overview['bundle']['total_size_bytes'])})")
    lines.append("")

    resource_info = overview["resources"]
    lines.append(
        f"Resources: {len(resource_info['resources'])} total "
        f"({resource_info['buffer_count']} buffers, {resource_info['texture_count']} textures, {resource_info['surface_count']} surfaces)"
    )
    for entry in resource_info["resources"]:
        label = entry.get("label") or "(no label)"
        lines.append(
            f"  {entry['name']:24s}  {entry['type']:7s}  {format_bytes(entry['size_bytes']):>8s}  {label}"
        )

    shader_inventory = resource_info["shader_inventory"]
    if shader_inventory["libraries"]:
        lines.append("")
        lines.append("Shader libraries:")
        for library in shader_inventory["libraries"]:
            lines.append(f"  {library}")
    if shader_inventory["functions"]:
        lines.append("")
        lines.append("Shader functions:")
        for function_name in shader_inventory["functions"][:32]:
            lines.append(f"  {function_name}")
        remaining = len(shader_inventory["functions"]) - 32
        if remaining > 0:
            lines.append(f"  … {remaining} more")

    lines.append("")
    lines.append("Bundle files:")
    for entry in overview["bundle"]["files"]:
        lines.append(
            f"  {entry['path']:24s}  {entry['kind']:12s}  {format_bytes(entry['size_bytes']):>8s}  {entry['magic']}"
        )
    return "\n".join(lines)


def render_resources_text(overview: dict[str, Any]) -> str:
    lines = ["Resources:"]
    for entry in overview["resources"]["resources"]:
        label = entry.get("label") or "(no label)"
        lines.append(
            f"  {entry['name']:24s}  {entry['type']:7s}  {format_bytes(entry['size_bytes']):>8s}  {label}"
        )
    if not overview["resources"]["resources"]:
        lines.append("  (no raw resource snapshot files found)")
    return "\n".join(lines)


def render_strings_text(overview: dict[str, Any], limit: int) -> str:
    lines: list[str] = []
    for file_name, strings in sorted(overview["strings"].items()):
        lines.append(f"[{file_name}]")
        for entry in strings[:limit]:
            lines.append(f"  0x{entry['offset']:08x}  {entry['value']}")
        remaining = len(strings) - limit
        if remaining > 0:
            lines.append(f"  … {remaining} more")
        lines.append("")
    if not lines:
        lines.append("No printable strings extracted.")
    return "\n".join(lines).rstrip()


def format_field(value: Any) -> str:
    if isinstance(value, list):
        return "(" + ", ".join(f"{float(item):.6g}" for item in value) + ")"
    if isinstance(value, float):
        return f"{value:.6g}"
    return str(value)


def render_buffer_text(parsed: dict[str, Any]) -> str:
    lines = []
    label = parsed.get("label") or "(no label)"
    lines.append(f"Buffer: {parsed['resource']}  {label}")
    lines.append(
        f"Layout: {parsed['layout']}  stride={parsed['stride_bytes']} bytes  rows={parsed['total_rows']}"
    )
    lines.append("")
    for row in parsed["rows"]:
        display = " | ".join(format_field(field) for field in row["fields"])
        lines.append(f"  [{row['index']:>6}] {display}")
    if parsed["stats"]:
        lines.append("")
        lines.append("Field stats:")
        for stat in parsed["stats"]:
            lines.append(
                f"  field{stat['field']}: min={stat['min']:.6g} max={stat['max']:.6g} mean={stat['mean']:.6g}"
            )
    return "\n".join(lines)


def build_html_report(overview: dict[str, Any]) -> str:
    summary = overview["metadata_summary"]
    files_rows = "\n".join(
        f"<tr><td>{html.escape(entry['path'])}</td><td>{html.escape(entry['kind'])}</td><td>{entry['size_bytes']}</td><td><code>{html.escape(entry['magic'])}</code></td></tr>"
        for entry in overview["bundle"]["files"]
    )
    resources_rows = "\n".join(
        f"<tr><td>{html.escape(entry['name'])}</td><td>{html.escape(entry['type'])}</td><td>{entry['size_bytes']}</td><td>{html.escape(entry.get('label') or '')}</td></tr>"
        for entry in overview["resources"]["resources"]
    ) or "<tr><td colspan='4'>(no raw resource snapshot files found)</td></tr>"
    shader_rows = "\n".join(
        f"<li><code>{html.escape(name)}</code></li>"
        for name in overview["resources"]["shader_inventory"]["functions"]
    ) or "<li>(none extracted)</li>"
    library_rows = "\n".join(
        f"<li><code>{html.escape(name)}</code></li>"
        for name in overview["resources"]["shader_inventory"]["libraries"]
    ) or "<li>(none extracted)</li>"

    return f"""<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <title>GPU Trace Report</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; color: #111; }}
    h1, h2 {{ margin-bottom: 0.35em; }}
    table {{ border-collapse: collapse; width: 100%; margin: 12px 0 24px; }}
    th, td {{ border: 1px solid #ddd; padding: 8px 10px; text-align: left; vertical-align: top; }}
    th {{ background: #f4f6f8; }}
    code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
    .meta {{ display: grid; grid-template-columns: repeat(2, minmax(200px, 1fr)); gap: 12px; margin: 12px 0 24px; }}
    .card {{ background: #f7f9fb; border: 1px solid #dde4ea; border-radius: 10px; padding: 12px; }}
    details {{ margin-bottom: 14px; }}
    summary {{ cursor: pointer; font-weight: 600; }}
    pre {{ background: #0f1720; color: #f8fafc; padding: 12px; overflow: auto; border-radius: 8px; }}
  </style>
</head>
<body>
  <h1>GPU Trace Report</h1>
  <p><code>{html.escape(overview['path'])}</code></p>

  <div class=\"meta\">
    <div class=\"card\"><strong>UUID</strong><br>{html.escape(str(summary.get('uuid') or 'unknown'))}</div>
    <div class=\"card\"><strong>API</strong><br>{html.escape(str(summary.get('graphics_api') or 'unknown'))}</div>
    <div class=\"card\"><strong>Captured frames</strong><br>{html.escape(str(summary.get('captured_frames_count') or 'unknown'))}</div>
    <div class=\"card\"><strong>Bundle size</strong><br>{format_bytes(overview['bundle']['total_size_bytes'])}</div>
  </div>

  <h2>Resources</h2>
  <table>
    <thead><tr><th>Name</th><th>Type</th><th>Size (bytes)</th><th>Label</th></tr></thead>
    <tbody>
      {resources_rows}
    </tbody>
  </table>

  <h2>Shader inventory</h2>
  <div class=\"meta\">
    <div class=\"card\"><strong>Libraries</strong><ul>{library_rows}</ul></div>
    <div class=\"card\"><strong>Functions</strong><ul>{shader_rows}</ul></div>
  </div>

  <h2>Bundle files</h2>
  <table>
    <thead><tr><th>Path</th><th>Kind</th><th>Size (bytes)</th><th>Magic</th></tr></thead>
    <tbody>
      {files_rows}
    </tbody>
  </table>

  <h2>Metadata</h2>
  <pre>{html.escape(json.dumps(overview['metadata'], indent=2, sort_keys=True))}</pre>

  <details>
    <summary>Extracted strings</summary>
    <pre>{html.escape(json.dumps(overview['strings'], indent=2, sort_keys=True))}</pre>
  </details>
</body>
</html>
"""


def dump_json(value: Any) -> None:
    json.dump(sanitize_json(value), sys.stdout, indent=2)
    print()


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    commands = {"info", "files", "resources", "strings", "buffer", "report"}
    if argv and argv[0] not in commands and not argv[0].startswith("-"):
        argv.insert(0, "info")

    parser = argparse.ArgumentParser(description="Inspect MTLCaptureManager .gputrace bundles")
    subparsers = parser.add_subparsers(dest="command", required=True)

    info_parser = subparsers.add_parser("info", help="human or JSON overview of the capture")
    info_parser.add_argument("gputrace")
    info_parser.add_argument("--json", action="store_true")

    files_parser = subparsers.add_parser("files", help="list bundle files and sizes")
    files_parser.add_argument("gputrace")
    files_parser.add_argument("--json", action="store_true")

    resources_parser = subparsers.add_parser("resources", help="list resource snapshot files, labels, and shader inventory")
    resources_parser.add_argument("gputrace")
    resources_parser.add_argument("--json", action="store_true")

    strings_parser = subparsers.add_parser("strings", help="show printable strings extracted from bundle internals")
    strings_parser.add_argument("gputrace")
    strings_parser.add_argument("--limit", type=int, default=64)
    strings_parser.add_argument("--json", action="store_true")

    buffer_parser = subparsers.add_parser("buffer", help="decode a buffer snapshot by filename or label")
    buffer_parser.add_argument("gputrace")
    buffer_parser.add_argument("--buffer", required=True, help="buffer filename or label")
    buffer_parser.add_argument("--layout", default="float4", help="layout, e.g. float, float2, float4, float2,float4")
    buffer_parser.add_argument("--index", default="0-10", help="row index or inclusive range, e.g. 5 or 0-15")
    buffer_parser.add_argument("--json", action="store_true")

    report_parser = subparsers.add_parser("report", help="write an HTML report")
    report_parser.add_argument("gputrace")
    report_parser.add_argument("-o", "--output", required=True)

    args = parser.parse_args(argv)
    bundle = ensure_bundle(args.gputrace)
    overview = build_overview(bundle)

    if args.command == "info":
        if args.json:
            dump_json(overview)
        else:
            print(render_info_text(overview))
        return 0

    if args.command == "files":
        if args.json:
            dump_json(overview["bundle"])
        else:
            for entry in overview["bundle"]["files"]:
                print(f"{entry['path']:24s}  {entry['kind']:12s}  {entry['size_bytes']:>10d}  {entry['magic']}")
        return 0

    if args.command == "resources":
        if args.json:
            dump_json(overview["resources"])
        else:
            print(render_resources_text(overview))
            shader_inventory = overview["resources"]["shader_inventory"]
            if shader_inventory["libraries"]:
                print("\nShader libraries:")
                for name in shader_inventory["libraries"]:
                    print(f"  {name}")
            if shader_inventory["functions"]:
                print("\nShader functions:")
                for name in shader_inventory["functions"]:
                    print(f"  {name}")
        return 0

    if args.command == "strings":
        if args.json:
            dump_json(overview["strings"])
        else:
            print(render_strings_text(overview, args.limit))
        return 0

    if args.command == "buffer":
        parsed = load_buffer_rows(bundle, overview, args.buffer, args.layout, args.index)
        if args.json:
            dump_json(parsed)
        else:
            print(render_buffer_text(parsed))
        return 0

    if args.command == "report":
        report_path = Path(args.output)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(build_html_report(overview), encoding="utf-8")
        print(str(report_path.resolve()))
        return 0

    fail(f"Unhandled command: {args.command}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
