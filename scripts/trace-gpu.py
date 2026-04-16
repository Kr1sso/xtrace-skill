#!/usr/bin/env python3
"""trace-gpu.py — GPU/Metal analysis for Instruments traces.

Provides a compact summary of:
- GPU state utilization (Active / Idle / Off)
- GPU performance-state residency
- Metal application interval stats (command-buffer cadence)
- Command-buffer submissions and encoder activity
- Shader inventory and shader timeline data (when present)
- Metal GPU interval ownership, channels, and CPU→GPU latency
- Command-buffer lifecycle (submission → GPU start → completion)
- Driver activity and GPU counter metadata/intervals (when present)

No third-party deps. Requires `xctrace`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from typing import Any, DefaultDict, Dict, Iterable, List, Optional, Sequence, Tuple


TableExport = Dict[str, Any]


def _run(cmd: List[str]) -> str:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{p.stderr.strip()}")
    return p.stdout


def _parse_xml(text: str) -> ET.Element:
    try:
        return ET.fromstring(text)
    except ET.ParseError as e:
        raise RuntimeError(f"failed to parse xctrace XML export: {e}")


def _export_toc(trace_path: str) -> ET.Element:
    out = _run(["xctrace", "export", "--input", trace_path, "--toc"])
    return _parse_xml(out)


def _export_schema_node_legacy(trace_path: str, schema: str) -> Optional[ET.Element]:
    xpath = f"/trace-toc/run[@number=\"1\"]/data/table[@schema=\"{schema}\"]"
    out = _run(["xctrace", "export", "--input", trace_path, "--xpath", xpath])
    root = _parse_xml(out)
    return root.find("node")


def _table_refs_from_toc(toc: ET.Element) -> List[TableExport]:
    data = toc.find("./run[@number='1']/data")
    if data is None:
        return []

    refs: List[TableExport] = []
    for index, table in enumerate(data.findall("table"), start=1):
        schema = table.get("schema", "")
        attrs = {k: v for k, v in table.attrib.items() if k != "schema"}
        refs.append({"index": index, "schema": schema, "attrs": attrs})
    return refs


def _export_table_index(trace_path: str, table_index: int) -> Optional[ET.Element]:
    xpath = f"/trace-toc/run[@number=\"1\"]/data/table[{table_index}]"
    out = _run(["xctrace", "export", "--input", trace_path, "--xpath", xpath])
    root = _parse_xml(out)
    return root.find("node")


def _export_schema_nodes(trace_path: str, table_refs: Sequence[TableExport], schema: str) -> List[TableExport]:
    matches = [ref for ref in table_refs if ref.get("schema") == schema]
    if matches:
        out: List[TableExport] = []
        for ref in matches:
            node = _export_table_index(trace_path, int(ref["index"]))
            if node is not None:
                out.append(
                    {
                        "index": ref["index"],
                        "schema": schema,
                        "attrs": dict(ref.get("attrs", {})),
                        "node": node,
                    }
                )
        return out

    node = _export_schema_node_legacy(trace_path, schema)
    if node is None:
        return []
    return [{"index": 0, "schema": schema, "attrs": {}, "node": node}]


def _id_index(node: ET.Element) -> Dict[str, ET.Element]:
    idx: Dict[str, ET.Element] = {}
    for e in node.iter():
        eid = e.get("id")
        if eid:
            idx[eid] = e
    return idx


def _resolve_elem(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> Optional[ET.Element]:
    if elem is None:
        return None
    ref = elem.get("ref")
    if ref:
        return idx.get(ref)
    return elem


def _fmt(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> str:
    e = _resolve_elem(elem, idx)
    if e is None:
        return ""
    f = e.get("fmt", "")
    if f:
        return f
    return (e.text or "").strip()


def _ival(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> int:
    e = _resolve_elem(elem, idx)
    if e is None:
        return 0
    candidates = [
        (e.text or "").strip(),
        e.get("fmt", "").strip(),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        t = candidate.replace(",", "")
        if re.fullmatch(r"-?[0-9]+", t):
            try:
                return int(t)
            except ValueError:
                pass
        m = re.search(r"-?[0-9]+", t)
        if m:
            try:
                return int(m.group(0))
            except ValueError:
                pass
    return 0


def _fval(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> float:
    e = _resolve_elem(elem, idx)
    if e is None:
        return 0.0
    candidates = [
        (e.text or "").strip(),
        e.get("fmt", "").strip(),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        t = candidate.replace(",", "").replace("%", "")
        m = re.search(r"-?[0-9]+(?:\.[0-9]+)?", t)
        if m:
            try:
                return float(m.group(0))
            except ValueError:
                pass
    return 0.0


def _find_child(row: ET.Element, name: str) -> Optional[ET.Element]:
    for c in row:
        if c.tag == name:
            return c
    return None


def _find_all_children(row: ET.Element, name: str) -> List[ET.Element]:
    return [c for c in row if c.tag == name]


def _all_fmt(row: ET.Element, idx: Dict[str, ET.Element], name: str) -> List[str]:
    vals = []
    for elem in _find_all_children(row, name):
        v = _fmt(elem, idx)
        if v:
            vals.append(v)
    return vals


def _all_int(row: ET.Element, idx: Dict[str, ET.Element], name: str) -> List[int]:
    vals = []
    for elem in _find_all_children(row, name):
        vals.append(_ival(elem, idx))
    return vals


def _iter_rows(tables: Sequence[TableExport]) -> Iterable[Tuple[ET.Element, Dict[str, ET.Element], Dict[str, str]]]:
    for table in tables:
        node = table.get("node")
        if node is None:
            continue
        idx = _id_index(node)
        attrs = dict(table.get("attrs", {}))
        for row in node.findall("row"):
            yield row, idx, attrs


def _row_count(tables: Sequence[TableExport]) -> int:
    total = 0
    for table in tables:
        node = table.get("node")
        if node is not None:
            total += len(node.findall("row"))
    return total


def _ns_fmt(ns: int) -> str:
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.2f}s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.2f}ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.2f}µs"
    return f"{ns}ns"


def _bytes_fmt(num: int) -> str:
    value = float(num)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024.0 or unit == "TiB":
            return f"{value:.2f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{num} B"


def _target_from_toc(toc: ET.Element) -> Tuple[str, str]:
    proc = toc.find(".//process[@type='launched']")
    if proc is not None:
        return proc.get("name", ""), proc.get("pid", "")

    proc2 = toc.find(".//target/process")
    if proc2 is not None:
        return proc2.get("name", ""), proc2.get("pid", "")

    return "", ""


def _matches_target(process_fmt: str, target_name: str, target_pid: str, process_filter: str) -> bool:
    pf = process_fmt.lower()
    if process_filter:
        return process_filter.lower() in pf
    if target_pid and target_pid in process_fmt:
        return True
    if target_name and target_name.lower() in pf:
        return True
    return False


def _p95(sorted_values: Sequence[int]) -> int:
    if not sorted_values:
        return 0
    index = max(0, int(round(0.95 * len(sorted_values) + 0.0000001)) - 1)
    if index >= len(sorted_values):
        index = len(sorted_values) - 1
    return int(sorted_values[index])


def _ns_stats(values: Sequence[int]) -> Dict[str, Any]:
    if not values:
        return {"count": 0, "total_ns": 0}
    ordered = sorted(int(v) for v in values)
    total = int(sum(ordered))
    return {
        "count": len(ordered),
        "total_ns": total,
        "avg_ns": int(total / len(ordered)),
        "median_ns": int(statistics.median(ordered)),
        "p95_ns": _p95(ordered),
        "min_ns": int(ordered[0]),
        "max_ns": int(ordered[-1]),
    }


def _float_stats(values: Sequence[float]) -> Dict[str, Any]:
    if not values:
        return {"count": 0}
    ordered = sorted(float(v) for v in values)
    total = float(sum(ordered))
    p95_index = max(0, int(round(0.95 * len(ordered) + 0.0000001)) - 1)
    if p95_index >= len(ordered):
        p95_index = len(ordered) - 1
    return {
        "count": len(ordered),
        "avg": total / len(ordered),
        "median": statistics.median(ordered),
        "p95": ordered[p95_index],
        "min": ordered[0],
        "max": ordered[-1],
    }


def _section_unavailable(reason: str) -> Dict[str, Any]:
    return {"available": False, "reason": reason}


def _availability_reason(tables: Sequence[TableExport], schema: str) -> str:
    if not tables:
        return f"schema not present: {schema}"
    return f"no rows recorded for schema: {schema}"


def _base_shader_name(label: str) -> str:
    if not label:
        return ""
    return re.sub(r"\s+\([0-9]+\)$", "", label).strip()


def _short_formatted_label(label: str) -> str:
    text = (label or "").strip().replace("\n", " ")
    if not text:
        return ""
    for marker in ("     (", "    (", "   (", "  ("):
        if marker in text:
            return text.split(marker, 1)[0].strip()
    return text


def _parse_submission_narrative(text: str) -> Tuple[str, int]:
    if not text:
        return "", 0
    m = re.search(r'Committed\s+"\s*(.*?)\s*"\s+with\s+([0-9]+)\s+encoders', text)
    if not m:
        return "", 0
    return m.group(1).strip(), int(m.group(2))


def _counter_top_ns(counter: Dict[str, int], limit: int = 8) -> List[Tuple[str, int]]:
    return sorted(counter.items(), key=lambda kv: kv[1], reverse=True)[:limit]


def summarize_device_info(metal_gpu_tables: Sequence[TableExport], device_gpu_tables: Sequence[TableExport]) -> Dict[str, Any]:
    if not metal_gpu_tables and not device_gpu_tables:
        return _section_unavailable("schemas not present: metal-gpu-info, device-gpu-info")

    device_name = ""
    vendor = ""
    memory_bytes = 0
    driver_version = ""

    for row, idx, _attrs in _iter_rows(device_gpu_tables):
        labels = _all_fmt(row, idx, "metal-object-label")
        if labels and not device_name:
            device_name = labels[0]
        if len(labels) > 1 and not vendor:
            vendor = labels[1]
        sizes = _all_int(row, idx, "size-in-bytes")
        if sizes and not memory_bytes:
            memory_bytes = sizes[0]
        strings = _all_fmt(row, idx, "string")
        if strings and not driver_version:
            driver_version = strings[0]
        break

    if not device_name:
        for row, idx, _attrs in _iter_rows(metal_gpu_tables):
            labels = _all_fmt(row, idx, "metal-object-label")
            if labels:
                device_name = labels[0]
                break

    if not device_name and not vendor and not memory_bytes and not driver_version:
        return _section_unavailable("no rows recorded for schemas: metal-gpu-info, device-gpu-info")

    return {
        "available": True,
        "device_name": device_name,
        "vendor": vendor,
        "memory_bytes": memory_bytes,
        "driver_version": driver_version,
    }


def summarize_gpu_states(tables: Sequence[TableExport]) -> Dict[str, Any]:
    if not tables:
        return _section_unavailable("schema not present: metal-gpu-state-intervals")

    by_state_ns: DefaultDict[str, int] = defaultdict(int)
    total_ns = 0
    rows = 0

    for row, idx, _attrs in _iter_rows(tables):
        dur = _ival(_find_child(row, "duration"), idx)
        state = _fmt(_find_child(row, "gpu-state"), idx) or "Unknown"
        rows += 1
        total_ns += dur
        by_state_ns[state] += dur

    if rows == 0:
        return _section_unavailable("no rows recorded for schema: metal-gpu-state-intervals")

    active_ns = by_state_ns.get("Active", 0)
    idle_ns = by_state_ns.get("Idle", 0)
    return {
        "available": True,
        "rows": rows,
        "total_ns": total_ns,
        "active_ns": active_ns,
        "idle_ns": idle_ns,
        "active_ratio": (active_ns / total_ns) if total_ns > 0 else 0.0,
        "idle_ratio": (idle_ns / total_ns) if total_ns > 0 else 0.0,
        "by_state_ns": dict(sorted(by_state_ns.items(), key=lambda kv: kv[1], reverse=True)),
    }


def summarize_performance_states(tables: Sequence[TableExport]) -> Dict[str, Any]:
    if not tables:
        return _section_unavailable("schema not present: gpu-performance-state-intervals")

    by_state_ns: DefaultDict[str, int] = defaultdict(int)
    total_ns = 0
    rows = 0

    for row, idx, _attrs in _iter_rows(tables):
        dur = _ival(_find_child(row, "duration"), idx)
        state = _fmt(_find_child(row, "gpu-performance-state"), idx) or "Unknown"
        rows += 1
        total_ns += dur
        by_state_ns[state] += dur

    if rows == 0:
        return _section_unavailable("no rows recorded for schema: gpu-performance-state-intervals")

    return {
        "available": True,
        "rows": rows,
        "total_ns": total_ns,
        "by_state_ns": dict(sorted(by_state_ns.items(), key=lambda kv: kv[1], reverse=True)),
    }


def summarize_application_intervals(
    tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, Any]:
    if not tables:
        return _section_unavailable("schema not present: metal-application-intervals")

    target_rows = 0
    total_ns = 0
    cmd_durs: List[int] = []
    depth_counts: DefaultDict[str, int] = defaultdict(int)
    depth_ns: DefaultDict[str, int] = defaultdict(int)
    label_ns: DefaultDict[str, int] = defaultdict(int)

    for row, idx, _attrs in _iter_rows(tables):
        process_fmt = _fmt(_find_child(row, "process"), idx)
        if not _matches_target(process_fmt, target_name, target_pid, process_filter):
            continue

        dur = _ival(_find_child(row, "duration"), idx)
        depth = _fmt(_find_child(row, "metal-nesting-level"), idx) or "?"
        label = _short_formatted_label(_fmt(_find_child(row, "formatted-label"), idx)) or "<unknown>"

        target_rows += 1
        total_ns += dur
        depth_counts[depth] += 1
        depth_ns[depth] += dur
        label_ns[label] += dur

        if label.startswith("Command Buffer"):
            cmd_durs.append(dur)

    if target_rows == 0:
        return _section_unavailable("no rows matched target process in schema: metal-application-intervals")

    out: Dict[str, Any] = {
        "available": True,
        "target_rows": target_rows,
        "target_total_ns": total_ns,
        "depth_counts": dict(depth_counts),
        "depth_ns": dict(depth_ns),
        "top_labels": _counter_top_ns(label_ns),
        "command_buffers": {
            "count": len(cmd_durs),
            "total_ns": int(sum(cmd_durs)),
            "share_of_target_ns": (sum(cmd_durs) / total_ns) if total_ns > 0 else 0.0,
        },
    }
    if cmd_durs:
        out["command_buffers"].update(_ns_stats(cmd_durs))
    return out


def summarize_command_buffer_submissions(
    tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    if not tables:
        return _section_unavailable("schema not present: metal-application-command-buffer-submissions"), {}

    durations: List[int] = []
    encoder_times: List[int] = []
    encoder_counts: List[int] = []
    labels: Counter[str] = Counter()
    threads: Counter[str] = Counter()
    frames = set()
    by_id: Dict[str, Dict[str, Any]] = {}
    rows = 0

    for row, idx, _attrs in _iter_rows(tables):
        process_fmt = _fmt(_find_child(row, "process"), idx)
        if not _matches_target(process_fmt, target_name, target_pid, process_filter):
            continue

        start_ns = _ival(_find_child(row, "start-time"), idx)
        durs = _all_int(row, idx, "duration")
        total_ns = durs[0] if durs else 0
        encoder_time_ns = durs[1] if len(durs) > 1 else 0
        uints = _all_int(row, idx, "uint32")
        encoder_count = uints[0] if uints else 0
        frame_number = uints[1] if len(uints) > 1 else 0
        narratives = _all_fmt(row, idx, "narrative")
        label = ""
        if narratives:
            parsed_label, parsed_count = _parse_submission_narrative(narratives[0])
            label = parsed_label
            if parsed_count and not encoder_count:
                encoder_count = parsed_count
        if not label:
            metal_labels = _all_fmt(row, idx, "metal-object-label")
            label = metal_labels[0] if metal_labels else "<unnamed>"
        thread = _fmt(_find_child(row, "thread"), idx)
        cb_ids = _all_int(row, idx, "metal-command-buffer-id")
        cmdbuffer_id = str(cb_ids[0]) if cb_ids else ""

        rows += 1
        durations.append(total_ns)
        if encoder_time_ns:
            encoder_times.append(encoder_time_ns)
        encoder_counts.append(encoder_count)
        labels[label] += 1
        if thread:
            threads[thread] += 1
        if frame_number:
            frames.add(frame_number)
        if cmdbuffer_id:
            by_id[cmdbuffer_id] = {
                "submit_time_ns": start_ns,
                "label": label,
                "submit_duration_ns": total_ns,
                "encoder_time_ns": encoder_time_ns,
                "encoder_count": encoder_count,
            }

    if rows == 0:
        return _section_unavailable(
            "no rows matched target process in schema: metal-application-command-buffer-submissions"
        ), {}

    total_encoder_count = int(sum(encoder_counts))
    return (
        {
            "available": True,
            "count": rows,
            "frames": len(frames),
            "submit_durations": _ns_stats(durations),
            "encoder_times": _ns_stats(encoder_times),
            "encoder_counts": {
                "total": total_encoder_count,
                "avg": (total_encoder_count / len(encoder_counts)) if encoder_counts else 0.0,
                "max": max(encoder_counts) if encoder_counts else 0,
            },
            "top_labels": labels.most_common(8),
            "top_threads": threads.most_common(5),
        },
        by_id,
    )


def summarize_encoders(
    tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, Any]:
    if not tables:
        return _section_unavailable("schema not present: metal-application-encoders-list")

    durations: List[int] = []
    encoder_ns: DefaultDict[str, int] = defaultdict(int)
    cmdbuffer_counts: Counter[str] = Counter()
    event_counts: Counter[str] = Counter()
    frames = set()
    rows = 0

    for row, idx, _attrs in _iter_rows(tables):
        process_fmt = _fmt(_find_child(row, "process"), idx)
        if not _matches_target(process_fmt, target_name, target_pid, process_filter):
            continue

        dur = _ival(_find_child(row, "duration"), idx)
        frame = _ival(_find_child(row, "gpu-frame-number"), idx)
        labels = _all_fmt(row, idx, "metal-object-label")
        cmdbuffer_label = labels[0] if labels else "<unnamed>"
        encoder_label = labels[2] if len(labels) > 2 else (labels[1] if len(labels) > 1 else "<unnamed>")
        event_type = _fmt(_find_child(row, "metal-event-name"), idx) or "Unknown"

        rows += 1
        durations.append(dur)
        encoder_ns[encoder_label] += dur
        cmdbuffer_counts[cmdbuffer_label] += 1
        event_counts[event_type] += 1
        if frame:
            frames.add(frame)

    if rows == 0:
        return _section_unavailable("no rows matched target process in schema: metal-application-encoders-list")

    return {
        "available": True,
        "count": rows,
        "frames": len(frames),
        "durations": _ns_stats(durations),
        "top_encoders_by_time": _counter_top_ns(encoder_ns),
        "top_command_buffers_by_count": cmdbuffer_counts.most_common(8),
        "event_types": event_counts.most_common(8),
    }


def summarize_shader_inventory(
    tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, Any]:
    if not tables:
        return _section_unavailable("schema not present: metal-shader-profiler-shader-list")

    stage_counts: Counter[str] = Counter()
    shader_counts: Counter[str] = Counter()
    rows = 0

    for row, idx, _attrs in _iter_rows(tables):
        process_fmt = _fmt(_find_child(row, "process"), idx)
        if process_fmt and not _matches_target(process_fmt, target_name, target_pid, process_filter):
            continue

        labels = _all_fmt(row, idx, "metal-object-label")
        shader_label = labels[0] if labels else ""
        if not shader_label:
            continue
        shader_name = _base_shader_name(shader_label) or shader_label
        stage = _fmt(_find_child(row, "string"), idx) or "Unknown"

        rows += 1
        shader_counts[shader_name] += 1
        stage_counts[stage] += 1

    if rows == 0:
        return _section_unavailable("no rows matched target process in schema: metal-shader-profiler-shader-list")

    return {
        "available": True,
        "rows": rows,
        "unique_shaders": len(shader_counts),
        "stages": dict(stage_counts),
        "top_shaders": shader_counts.most_common(12),
    }


def summarize_shader_timeline(
    tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, Any]:
    if not tables:
        return _section_unavailable("schema not present: metal-shader-profiler-intervals")

    durations: List[int] = []
    work_pct: List[float] = []
    total_work_pct: List[float] = []
    shader_ns: DefaultDict[str, int] = defaultdict(int)
    channel_ns: DefaultDict[str, int] = defaultdict(int)
    stage_counts: Counter[str] = Counter()
    rows = 0

    for row, idx, _attrs in _iter_rows(tables):
        process_fmt = _fmt(_find_child(row, "process"), idx)
        if process_fmt and not _matches_target(process_fmt, target_name, target_pid, process_filter):
            continue

        dur = _ival(_find_child(row, "duration"), idx)
        labels = _all_fmt(row, idx, "metal-object-label")
        shader_name = _base_shader_name(labels[0]) if labels else "<unknown>"
        shader_type = labels[3] if len(labels) > 3 else (labels[-1] if labels else "Unknown")
        channel_name = _fmt(_find_child(row, "gpu-channel-name"), idx) or "Unknown"
        percents = [_fval(elem, idx) for elem in _find_all_children(row, "percent")]

        rows += 1
        durations.append(dur)
        shader_ns[shader_name] += dur
        channel_ns[channel_name] += dur
        stage_counts[shader_type] += 1
        if percents:
            work_pct.append(percents[0])
        if len(percents) > 1:
            total_work_pct.append(percents[1])

    if rows == 0:
        return _section_unavailable("no rows matched target process in schema: metal-shader-profiler-intervals")

    return {
        "available": True,
        "rows": rows,
        "durations": _ns_stats(durations),
        "top_shaders_by_time": _counter_top_ns(shader_ns),
        "channels": dict(sorted(channel_ns.items(), key=lambda kv: kv[1], reverse=True)),
        "shader_types": dict(stage_counts),
        "gpu_work_pct": _float_stats(work_pct),
        "total_gpu_work_pct": _float_stats(total_work_pct),
    }


def summarize_gpu_intervals(
    tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    if not tables:
        return _section_unavailable("schema not present: metal-gpu-intervals"), {}

    proc_ns: DefaultDict[str, int] = defaultdict(int)
    target_ns = 0
    target_rows = 0
    all_ns = 0
    channel_ns: DefaultDict[str, int] = defaultdict(int)
    label_ns: DefaultDict[str, int] = defaultdict(int)
    start_latencies: List[int] = []
    by_cmdbuffer: Dict[str, Dict[str, Any]] = {}

    for row, idx, _attrs in _iter_rows(tables):
        durations = _all_int(row, idx, "duration")
        dur = durations[0] if durations else 0
        start_latency = durations[1] if len(durations) > 1 else 0
        process_fmt = _fmt(_find_child(row, "process"), idx) or "<unknown>"
        proc_ns[process_fmt] += dur
        all_ns += dur

        if not _matches_target(process_fmt, target_name, target_pid, process_filter):
            continue

        start_ns = _ival(_find_child(row, "start-time"), idx)
        channel_name = _fmt(_find_child(row, "gpu-channel-name"), idx) or "Unknown"
        label = _short_formatted_label(_fmt(_find_child(row, "formatted-label"), idx)) or "<unknown>"
        cb_ids = _all_int(row, idx, "metal-command-buffer-id")
        cmdbuffer_id = str(cb_ids[0]) if cb_ids else ""

        target_rows += 1
        target_ns += dur
        channel_ns[channel_name] += dur
        label_ns[label] += dur
        if start_latency:
            start_latencies.append(start_latency)

        if cmdbuffer_id:
            item = by_cmdbuffer.setdefault(
                cmdbuffer_id,
                {
                    "busy_ns": 0,
                    "first_start_ns": start_ns,
                    "start_latencies": [],
                },
            )
            item["busy_ns"] += dur
            if start_ns and (item.get("first_start_ns", 0) == 0 or start_ns < item["first_start_ns"]):
                item["first_start_ns"] = start_ns
            if start_latency:
                item["start_latencies"].append(start_latency)

    if all_ns == 0:
        return _section_unavailable("no rows recorded for schema: metal-gpu-intervals"), {}

    top_procs = sorted(proc_ns.items(), key=lambda kv: kv[1], reverse=True)[:8]
    rep = {
        "available": True,
        "rows": _row_count(tables),
        "all_ns": all_ns,
        "target_rows": target_rows,
        "target_ns": target_ns,
        "target_share": (target_ns / all_ns) if all_ns > 0 else 0.0,
        "top_processes": top_procs,
        "channels": dict(sorted(channel_ns.items(), key=lambda kv: kv[1], reverse=True)),
        "top_target_labels": _counter_top_ns(label_ns),
        "cpu_to_gpu_start_latency": _ns_stats(start_latencies),
    }
    return rep, by_cmdbuffer


def summarize_command_buffer_lifecycle(
    submission_map: Dict[str, Dict[str, Any]],
    completion_tables: Sequence[TableExport],
    gpu_by_cmdbuffer: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    if not submission_map:
        return _section_unavailable("no command-buffer submissions were available for lifecycle correlation")

    completions: Dict[str, int] = {}
    for row, idx, _attrs in _iter_rows(completion_tables):
        cmdbuffer_id = str(_ival(_find_child(row, "metal-command-buffer-id"), idx))
        if not cmdbuffer_id or cmdbuffer_id == "0":
            continue
        start_ns = _ival(_find_child(row, "start-time"), idx)
        prev = completions.get(cmdbuffer_id)
        if prev is None or start_ns < prev:
            completions[cmdbuffer_id] = start_ns

    completion_latencies: List[int] = []
    submit_to_gpu_latencies: List[int] = []
    gpu_busy_durations: List[int] = []
    completed_count = 0
    gpu_correlated_count = 0

    for cmdbuffer_id, info in submission_map.items():
        submit_ns = int(info.get("submit_time_ns", 0))
        completion_ns = completions.get(cmdbuffer_id)
        if completion_ns is not None and completion_ns >= submit_ns:
            completion_latencies.append(completion_ns - submit_ns)
            completed_count += 1

        gpu_info = gpu_by_cmdbuffer.get(cmdbuffer_id)
        if gpu_info:
            first_start_ns = int(gpu_info.get("first_start_ns", 0))
            busy_ns = int(gpu_info.get("busy_ns", 0))
            if busy_ns:
                gpu_busy_durations.append(busy_ns)
            if first_start_ns and first_start_ns >= submit_ns:
                submit_to_gpu_latencies.append(first_start_ns - submit_ns)
            gpu_correlated_count += 1

    return {
        "available": True,
        "submitted_count": len(submission_map),
        "completed_count": completed_count,
        "completed_ratio": (completed_count / len(submission_map)) if submission_map else 0.0,
        "gpu_correlated_count": gpu_correlated_count,
        "submission_to_completion": _ns_stats(completion_latencies),
        "submission_to_gpu_start": _ns_stats(submit_to_gpu_latencies),
        "gpu_busy_per_command_buffer": _ns_stats(gpu_busy_durations),
    }


def summarize_driver_activity(
    interval_tables: Sequence[TableExport],
    event_tables: Sequence[TableExport],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, Any]:
    if not interval_tables and not event_tables:
        return _section_unavailable("schemas not present: metal-driver-intervals, metal-driver-event-intervals")

    driver_ns: DefaultDict[str, int] = defaultdict(int)
    event_ns: DefaultDict[str, int] = defaultdict(int)
    total_ns = 0
    rows = 0

    for tables, kind in ((interval_tables, "interval"), (event_tables, "event")):
        for row, idx, _attrs in _iter_rows(tables):
            process_fmt = _fmt(_find_child(row, "process"), idx)
            if process_fmt and not _matches_target(process_fmt, target_name, target_pid, process_filter):
                continue

            dur = _ival(_find_child(row, "duration"), idx)
            driver_names = _all_fmt(row, idx, "gpu-driver-name")
            driver_name = driver_names[0] if driver_names else "Driver"
            if kind == "interval":
                event_type = _fmt(_find_child(row, "metal-object-label"), idx) or driver_name
            else:
                event_type = driver_names[1] if len(driver_names) > 1 else driver_name
            rows += 1
            total_ns += dur
            driver_ns[driver_name] += dur
            event_ns[f"{driver_name} / {event_type}"] += dur

    if rows == 0:
        return _section_unavailable(
            "no rows matched target process in schemas: metal-driver-intervals, metal-driver-event-intervals"
        )

    return {
        "available": True,
        "rows": rows,
        "total_ns": total_ns,
        "top_driver_phases": _counter_top_ns(driver_ns),
        "top_events": _counter_top_ns(event_ns),
    }


def summarize_gpu_counters(
    info_tables: Sequence[TableExport],
    interval_tables: Sequence[TableExport],
) -> Dict[str, Any]:
    if not info_tables and not interval_tables:
        return _section_unavailable("schemas not present: gpu-counter-info, metal-gpu-counter-intervals")

    metadata: List[Dict[str, Any]] = []
    seen_ids = set()

    for row, idx, attrs in _iter_rows(info_tables):
        uints = _all_int(row, idx, "uint32")
        counter_id = uints[0] if uints else 0
        if counter_id in seen_ids:
            continue
        seen_ids.add(counter_id)
        strings = _all_fmt(row, idx, "string")
        uint64s = _all_int(row, idx, "uint64")
        metadata.append(
            {
                "counter_id": counter_id,
                "name": _fmt(_find_child(row, "gpu-counter-name"), idx) or f"counter-{counter_id}",
                "type": strings[1] if len(strings) > 1 else (strings[0] if strings else ""),
                "description": strings[0] if strings else "",
                "max_value": uint64s[0] if uint64s else 0,
                "profile": attrs.get("counter-profile", ""),
                "shader_profiler": attrs.get("shader-profiler", ""),
            }
        )

    interval_rows = 0
    counter_ns: DefaultDict[str, int] = defaultdict(int)
    counter_values: DefaultDict[str, List[float]] = defaultdict(list)

    for row, idx, _attrs in _iter_rows(interval_tables):
        interval_rows += 1
        dur = _ival(_find_child(row, "duration"), idx)
        name = _fmt(_find_child(row, "gpu-counter-name"), idx) or "<unknown>"
        value = _fval(_find_child(row, "fixed-decimal"), idx)
        counter_ns[name] += dur
        counter_values[name].append(value)

    result: Dict[str, Any] = {
        "available": True,
        "metadata_count": len(metadata),
        "metadata": metadata[:16],
    }

    if interval_rows == 0:
        result["intervals"] = _section_unavailable(
            _availability_reason(interval_tables, "metal-gpu-counter-intervals")
        )
    else:
        top_counters = []
        for name, total_ns in sorted(counter_ns.items(), key=lambda kv: kv[1], reverse=True)[:12]:
            stats = _float_stats(counter_values[name])
            top_counters.append(
                {
                    "name": name,
                    "total_ns": total_ns,
                    "value_stats": stats,
                }
            )
        result["intervals"] = {
            "available": True,
            "rows": interval_rows,
            "top_counters": top_counters,
        }

    return result


def summarize(trace_path: str, process_filter: str = "") -> Dict[str, Any]:
    toc = _export_toc(trace_path)
    target_name, target_pid = _target_from_toc(toc)
    table_refs = _table_refs_from_toc(toc)

    metal_gpu_info_tables = _export_schema_nodes(trace_path, table_refs, "metal-gpu-info")
    device_gpu_info_tables = _export_schema_nodes(trace_path, table_refs, "device-gpu-info")
    gpu_state_tables = _export_schema_nodes(trace_path, table_refs, "metal-gpu-state-intervals")
    perf_state_tables = _export_schema_nodes(trace_path, table_refs, "gpu-performance-state-intervals")
    app_interval_tables = _export_schema_nodes(trace_path, table_refs, "metal-application-intervals")
    submission_tables = _export_schema_nodes(trace_path, table_refs, "metal-application-command-buffer-submissions")
    encoder_tables = _export_schema_nodes(trace_path, table_refs, "metal-application-encoders-list")
    shader_list_tables = _export_schema_nodes(trace_path, table_refs, "metal-shader-profiler-shader-list")
    shader_interval_tables = _export_schema_nodes(trace_path, table_refs, "metal-shader-profiler-intervals")
    gpu_interval_tables = _export_schema_nodes(trace_path, table_refs, "metal-gpu-intervals")
    completion_tables = _export_schema_nodes(trace_path, table_refs, "metal-command-buffer-completed")
    driver_interval_tables = _export_schema_nodes(trace_path, table_refs, "metal-driver-intervals")
    driver_event_tables = _export_schema_nodes(trace_path, table_refs, "metal-driver-event-intervals")
    counter_info_tables = _export_schema_nodes(trace_path, table_refs, "gpu-counter-info")
    counter_interval_tables = _export_schema_nodes(trace_path, table_refs, "metal-gpu-counter-intervals")

    command_buffer_submissions, submission_map = summarize_command_buffer_submissions(
        submission_tables, target_name, target_pid, process_filter
    )
    gpu_intervals, gpu_by_cmdbuffer = summarize_gpu_intervals(
        gpu_interval_tables, target_name, target_pid, process_filter
    )

    unique_schemas = sorted({ref.get("schema", "") for ref in table_refs if ref.get("schema")})

    return {
        "trace": os.path.abspath(trace_path),
        "target_name": target_name,
        "target_pid": target_pid,
        "process_filter": process_filter,
        "metal_schemas": unique_schemas,
        "device": summarize_device_info(metal_gpu_info_tables, device_gpu_info_tables),
        "gpu_states": summarize_gpu_states(gpu_state_tables),
        "performance_states": summarize_performance_states(perf_state_tables),
        "app_intervals": summarize_application_intervals(
            app_interval_tables, target_name, target_pid, process_filter
        ),
        "command_buffer_submissions": command_buffer_submissions,
        "encoders": summarize_encoders(encoder_tables, target_name, target_pid, process_filter),
        "shader_inventory": summarize_shader_inventory(shader_list_tables, target_name, target_pid, process_filter),
        "shader_timeline": summarize_shader_timeline(
            shader_interval_tables, target_name, target_pid, process_filter
        ),
        "gpu_intervals": gpu_intervals,
        "command_buffer_lifecycle": summarize_command_buffer_lifecycle(
            submission_map, completion_tables, gpu_by_cmdbuffer
        ),
        "driver_activity": summarize_driver_activity(
            driver_interval_tables, driver_event_tables, target_name, target_pid, process_filter
        ),
        "gpu_counters": summarize_gpu_counters(counter_info_tables, counter_interval_tables),
    }


def _print_ns_stats(prefix: str, stats: Dict[str, Any]) -> None:
    if not stats or stats.get("count", 0) == 0:
        print(f"{prefix}: unavailable")
        return
    print(
        f"{prefix}: count={stats['count']}, avg={_ns_fmt(stats['avg_ns'])}, "
        f"median={_ns_fmt(stats['median_ns'])}, p95={_ns_fmt(stats['p95_ns'])}, "
        f"min={_ns_fmt(stats['min_ns'])}, max={_ns_fmt(stats['max_ns'])}"
    )


def _print_top_time_list(items: Sequence[Tuple[str, int]], indent: str = "  - ") -> None:
    if not items:
        print(f"{indent}<none>")
        return
    total = sum(ns for _name, ns in items)
    for name, ns in items:
        share = (ns / total * 100.0) if total > 0 else 0.0
        print(f"{indent}{name}: {_ns_fmt(ns)} ({share:.1f}% of listed)")


def _print_section(title: str) -> None:
    print(f"[{title}]")


def _print_unavailable(title: str, section: Dict[str, Any]) -> None:
    _print_section(title)
    print(f"unavailable: {section.get('reason', 'unknown')}")
    print()


def _print_human(rep: Dict[str, Any]) -> None:
    print("GPU / Metal Summary")
    print("===================")
    print(f"Trace: {rep['trace']}")
    print(f"Target: {rep.get('target_name') or '<unknown>'} (pid {rep.get('target_pid') or '?'})")
    if rep.get("process_filter"):
        print(f"Process filter override: {rep['process_filter']}")
    print()

    device = rep["device"]
    if device.get("available"):
        _print_section("GPU device")
        line = device.get("device_name") or "<unknown>"
        if device.get("vendor"):
            line += f" — {device['vendor']}"
        print(line)
        if device.get("memory_bytes"):
            print(f"Memory: {_bytes_fmt(int(device['memory_bytes']))}")
        if device.get("driver_version"):
            print(f"Driver: {device['driver_version']}")
        print()
    else:
        _print_unavailable("GPU device", device)

    gs = rep["gpu_states"]
    if gs.get("available"):
        _print_section("GPU state utilization")
        print(f"Rows: {gs['rows']}")
        print(f"Active: {_ns_fmt(gs['active_ns'])} ({gs['active_ratio'] * 100:.1f}%)")
        print(f"Idle:   {_ns_fmt(gs['idle_ns'])} ({gs['idle_ratio'] * 100:.1f}%)")
        for state, ns in gs["by_state_ns"].items():
            print(f"  - {state}: {_ns_fmt(ns)}")
        print()
    else:
        _print_unavailable("GPU state utilization", gs)

    ps = rep["performance_states"]
    if ps.get("available"):
        _print_section("GPU performance states")
        print(f"Rows: {ps['rows']}, total: {_ns_fmt(ps['total_ns'])}")
        for state, ns in ps["by_state_ns"].items():
            share = (ns / ps["total_ns"] * 100.0) if ps["total_ns"] > 0 else 0.0
            print(f"  - {state}: {_ns_fmt(ns)} ({share:.1f}%)")
        print()
    else:
        _print_unavailable("GPU performance states", ps)

    ai = rep["app_intervals"]
    if ai.get("available"):
        _print_section("Metal application intervals (target process)")
        print(f"Rows: {ai['target_rows']}, total: {_ns_fmt(ai['target_total_ns'])}")
        cb = ai["command_buffers"]
        print(
            f"Command-buffer-like interval rows: count={cb.get('count', 0)}, "
            f"share={cb.get('share_of_target_ns', 0.0) * 100:.1f}%"
        )
        if ai.get("depth_counts"):
            print("By nesting depth:")
            for depth, cnt in sorted(ai["depth_counts"].items(), key=lambda kv: kv[0]):
                print(f"  - depth {depth}: count={cnt}, total={_ns_fmt(ai['depth_ns'].get(depth, 0))}")
        if ai.get("top_labels"):
            print("Top interval labels:")
            _print_top_time_list(ai["top_labels"], indent="  - ")
        print()
    else:
        _print_unavailable("Metal application intervals (target process)", ai)

    cbs = rep["command_buffer_submissions"]
    if cbs.get("available"):
        _print_section("Command-buffer submissions")
        print(f"Count: {cbs['count']} over {cbs.get('frames', 0)} frame(s)")
        _print_ns_stats("Submission duration", cbs["submit_durations"])
        _print_ns_stats("Encoder time", cbs["encoder_times"])
        ec = cbs["encoder_counts"]
        print(f"Encoders per submission: avg={ec.get('avg', 0.0):.2f}, max={ec.get('max', 0)}, total={ec.get('total', 0)}")
        if cbs.get("top_labels"):
            print("Top command-buffer labels:")
            for label, count in cbs["top_labels"]:
                print(f"  - {label}: {count}")
        print()
    else:
        _print_unavailable("Command-buffer submissions", cbs)

    enc = rep["encoders"]
    if enc.get("available"):
        _print_section("Encoder activity")
        print(f"Rows: {enc['count']} across {enc.get('frames', 0)} frame(s)")
        _print_ns_stats("Encoder duration", enc["durations"])
        if enc.get("top_encoders_by_time"):
            print("Top encoders by time:")
            _print_top_time_list(enc["top_encoders_by_time"], indent="  - ")
        if enc.get("event_types"):
            print("Encoder event types:")
            for event_name, count in enc["event_types"]:
                print(f"  - {event_name}: {count}")
        print()
    else:
        _print_unavailable("Encoder activity", enc)

    inv = rep["shader_inventory"]
    if inv.get("available"):
        _print_section("Shader inventory")
        print(f"Rows: {inv['rows']}, unique shaders: {inv['unique_shaders']}")
        if inv.get("stages"):
            print("Shader stages:")
            for stage, count in inv["stages"].items():
                print(f"  - {stage}: {count}")
        if inv.get("top_shaders"):
            print("Top shaders:")
            for shader, count in inv["top_shaders"]:
                print(f"  - {shader}: {count}")
        print()
    else:
        _print_unavailable("Shader inventory", inv)

    st = rep["shader_timeline"]
    if st.get("available"):
        _print_section("Shader timeline")
        print(f"Rows: {st['rows']}")
        _print_ns_stats("Shader interval duration", st["durations"])
        if st.get("top_shaders_by_time"):
            print("Top shaders by time:")
            _print_top_time_list(st["top_shaders_by_time"], indent="  - ")
        if st.get("channels"):
            print("Channels:")
            for channel, ns in st["channels"].items():
                print(f"  - {channel}: {_ns_fmt(ns)}")
        if st.get("shader_types"):
            print("Shader types:")
            for shader_type, count in st["shader_types"].items():
                print(f"  - {shader_type}: {count}")
        if st.get("gpu_work_pct", {}).get("count", 0) > 0:
            pct = st["gpu_work_pct"]
            print(f"% GPU Work: avg={pct['avg']:.2f}, median={pct['median']:.2f}, p95={pct['p95']:.2f}")
        print()
    else:
        _print_unavailable("Shader timeline", st)

    gi = rep["gpu_intervals"]
    if gi.get("available"):
        _print_section("Metal GPU intervals")
        print(
            f"Rows={gi['rows']}, total={_ns_fmt(gi['all_ns'])}, "
            f"target={_ns_fmt(gi['target_ns'])} ({gi['target_share'] * 100:.1f}%)"
        )
        print("Top GPU interval owners:")
        for proc, ns in gi["top_processes"]:
            share = (ns / gi["all_ns"] * 100.0) if gi["all_ns"] > 0 else 0.0
            print(f"  - {proc}: {_ns_fmt(ns)} ({share:.1f}%)")
        if gi.get("channels"):
            print("Target channels:")
            for channel, ns in gi["channels"].items():
                print(f"  - {channel}: {_ns_fmt(ns)}")
        _print_ns_stats("CPU→GPU start latency", gi["cpu_to_gpu_start_latency"])
        if gi.get("top_target_labels"):
            print("Top GPU labels for target:")
            _print_top_time_list(gi["top_target_labels"], indent="  - ")
        print()
    else:
        _print_unavailable("Metal GPU intervals", gi)

    life = rep["command_buffer_lifecycle"]
    if life.get("available"):
        _print_section("Command-buffer lifecycle")
        print(
            f"Submitted={life['submitted_count']}, completed={life['completed_count']} "
            f"({life['completed_ratio'] * 100:.1f}%), GPU-correlated={life['gpu_correlated_count']}"
        )
        _print_ns_stats("Submission→GPU start", life["submission_to_gpu_start"])
        _print_ns_stats("Submission→completion", life["submission_to_completion"])
        _print_ns_stats("GPU busy / command buffer", life["gpu_busy_per_command_buffer"])
        print()
    else:
        _print_unavailable("Command-buffer lifecycle", life)

    driver = rep["driver_activity"]
    if driver.get("available"):
        _print_section("Driver activity")
        print(f"Rows: {driver['rows']}, total: {_ns_fmt(driver['total_ns'])}")
        if driver.get("top_driver_phases"):
            print("Top driver phases:")
            _print_top_time_list(driver["top_driver_phases"], indent="  - ")
        if driver.get("top_events"):
            print("Top driver events:")
            _print_top_time_list(driver["top_events"], indent="  - ")
        print()
    else:
        _print_unavailable("Driver activity", driver)

    counters = rep["gpu_counters"]
    if counters.get("available"):
        _print_section("GPU counters")
        print(f"Counter metadata rows: {counters.get('metadata_count', 0)}")
        for meta in counters.get("metadata", [])[:8]:
            desc = f" [{meta['type']}]" if meta.get("type") else ""
            print(f"  - {meta['name']} (id={meta['counter_id']}){desc}")
        intervals = counters.get("intervals", {})
        if intervals.get("available"):
            print(f"Aggregated interval rows: {intervals.get('rows', 0)}")
            for item in intervals.get("top_counters", []):
                stats = item.get("value_stats", {})
                if stats.get("count", 0) > 0:
                    print(
                        f"  - {item['name']}: {_ns_fmt(item['total_ns'])}, "
                        f"avg={stats['avg']:.4f}, max={stats['max']:.4f}"
                    )
        else:
            print(f"Aggregated intervals unavailable: {intervals.get('reason', 'unknown')}")
        print()
    else:
        _print_unavailable("GPU counters", counters)


def main() -> int:
    ap = argparse.ArgumentParser(description="Analyze GPU-centric metrics from Instruments traces")
    ap.add_argument("trace", help=".trace bundle path")
    ap.add_argument("--json", action="store_true", help="Output JSON report")
    ap.add_argument(
        "--process",
        default="",
        help="Optional process substring override for filtering rows (default: launched target in trace)",
    )
    args = ap.parse_args()

    rep = summarize(args.trace, process_filter=args.process)
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        _print_human(rep)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
