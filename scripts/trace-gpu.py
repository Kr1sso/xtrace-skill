#!/usr/bin/env python3
"""trace-gpu.py — GPU-focused analysis for Instruments Metal System Trace files.

Provides a compact summary of:
- GPU state utilization (Active / Idle / Off)
- Metal application interval stats (command-buffer cadence)
- Metal GPU interval ownership (target process vs others)

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
from collections import defaultdict
from typing import Dict, Iterable, List, Optional, Tuple


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


def _export_schema_node(trace_path: str, schema: str) -> Optional[ET.Element]:
    xpath = f"/trace-toc/run[@number=\"1\"]/data/table[@schema=\"{schema}\"]"
    out = _run(["xctrace", "export", "--input", trace_path, "--xpath", xpath])
    root = _parse_xml(out)
    node = root.find("node")
    return node


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
    t = (e.text or "").strip().replace(",", "")
    try:
        return int(t)
    except ValueError:
        return 0


def _find_child(row: ET.Element, name: str) -> Optional[ET.Element]:
    for c in row:
        if c.tag == name:
            return c
    return None


def _find_all_children(row: ET.Element, name: str) -> List[ET.Element]:
    return [c for c in row if c.tag == name]


def _ns_fmt(ns: int) -> str:
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.2f}s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.2f}ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.2f}µs"
    return f"{ns}ns"


def _target_from_toc(toc: ET.Element) -> Tuple[str, str]:
    # Typical format in --toc:
    # <process type="launched" ... name="foo" pid="123"/>
    proc = toc.find(".//process[@type='launched']")
    if proc is not None:
        return proc.get("name", ""), proc.get("pid", "")

    # Fallback: first process under target
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


def summarize_gpu_states(node: Optional[ET.Element]) -> Dict[str, object]:
    if node is None:
        return {
            "available": False,
            "reason": "schema not present: metal-gpu-state-intervals",
        }

    idx = _id_index(node)
    by_state_ns: Dict[str, int] = defaultdict(int)
    total_ns = 0
    rows = node.findall("row")

    for r in rows:
        dur = _ival(_find_child(r, "duration"), idx)
        state = _fmt(_find_child(r, "gpu-state"), idx) or "Unknown"
        total_ns += dur
        by_state_ns[state] += dur

    active_ns = by_state_ns.get("Active", 0)
    idle_ns = by_state_ns.get("Idle", 0)

    return {
        "available": True,
        "rows": len(rows),
        "total_ns": total_ns,
        "active_ns": active_ns,
        "idle_ns": idle_ns,
        "active_ratio": (active_ns / total_ns) if total_ns > 0 else 0.0,
        "idle_ratio": (idle_ns / total_ns) if total_ns > 0 else 0.0,
        "by_state_ns": dict(sorted(by_state_ns.items(), key=lambda kv: kv[1], reverse=True)),
    }


def summarize_application_intervals(
    node: Optional[ET.Element],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, object]:
    if node is None:
        return {
            "available": False,
            "reason": "schema not present: metal-application-intervals",
        }

    idx = _id_index(node)
    rows = node.findall("row")

    target_rows = []
    cmd_durs = []
    depth_counts: Dict[str, int] = defaultdict(int)
    depth_ns: Dict[str, int] = defaultdict(int)

    for r in rows:
        p = _fmt(_find_child(r, "process"), idx)
        if not _matches_target(p, target_name, target_pid, process_filter):
            continue

        dur = _ival(_find_child(r, "duration"), idx)
        depth = _fmt(_find_child(r, "metal-nesting-level"), idx)
        label = _fmt(_find_child(r, "formatted-label"), idx)

        target_rows.append((dur, depth, label))
        depth_counts[depth] += 1
        depth_ns[depth] += dur

        if label.startswith("Command Buffer"):
            cmd_durs.append(dur)

    total_ns = sum(d for d, _, _ in target_rows)

    def _pct(vals: Iterable[int], total: int) -> float:
        s = sum(vals)
        return (s / total) if total > 0 else 0.0

    out = {
        "available": True,
        "target_rows": len(target_rows),
        "target_total_ns": total_ns,
        "depth_counts": dict(depth_counts),
        "depth_ns": dict(depth_ns),
        "command_buffers": {
            "count": len(cmd_durs),
            "total_ns": sum(cmd_durs),
            "share_of_target_ns": _pct(cmd_durs, total_ns),
        },
    }

    if cmd_durs:
        out["command_buffers"].update(
            {
                "avg_ns": int(sum(cmd_durs) / len(cmd_durs)),
                "median_ns": int(statistics.median(cmd_durs)),
                "p95_ns": int(sorted(cmd_durs)[max(0, int(0.95 * len(cmd_durs)) - 1)]),
                "min_ns": int(min(cmd_durs)),
                "max_ns": int(max(cmd_durs)),
            }
        )

    return out


def summarize_gpu_intervals(
    node: Optional[ET.Element],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> Dict[str, object]:
    if node is None:
        return {
            "available": False,
            "reason": "schema not present: metal-gpu-intervals",
        }

    idx = _id_index(node)
    rows = node.findall("row")

    proc_ns: Dict[str, int] = defaultdict(int)
    target_ns = 0
    target_rows = 0
    all_ns = 0

    for r in rows:
        durs = _find_all_children(r, "duration")
        dur = _ival(durs[0], idx) if durs else 0
        p = _fmt(_find_child(r, "process"), idx)
        if not p:
            p = "<unknown>"

        proc_ns[p] += dur
        all_ns += dur

        if _matches_target(p, target_name, target_pid, process_filter):
            target_ns += dur
            target_rows += 1

    top_procs = sorted(proc_ns.items(), key=lambda kv: kv[1], reverse=True)[:8]

    return {
        "available": True,
        "rows": len(rows),
        "all_ns": all_ns,
        "target_rows": target_rows,
        "target_ns": target_ns,
        "target_share": (target_ns / all_ns) if all_ns > 0 else 0.0,
        "top_processes": top_procs,
    }


def summarize(trace_path: str, process_filter: str = "") -> Dict[str, object]:
    toc = _export_toc(trace_path)
    target_name, target_pid = _target_from_toc(toc)

    gpu_state_node = _export_schema_node(trace_path, "metal-gpu-state-intervals")
    app_node = _export_schema_node(trace_path, "metal-application-intervals")
    gpu_node = _export_schema_node(trace_path, "metal-gpu-intervals")

    return {
        "trace": os.path.abspath(trace_path),
        "target_name": target_name,
        "target_pid": target_pid,
        "process_filter": process_filter,
        "gpu_states": summarize_gpu_states(gpu_state_node),
        "app_intervals": summarize_application_intervals(app_node, target_name, target_pid, process_filter),
        "gpu_intervals": summarize_gpu_intervals(gpu_node, target_name, target_pid, process_filter),
    }


def _print_human(rep: Dict[str, object]) -> None:
    print("GPU Summary")
    print("===========")
    print(f"Trace: {rep['trace']}")
    print(f"Target: {rep.get('target_name') or '<unknown>'} (pid {rep.get('target_pid') or '?'})")
    if rep.get("process_filter"):
        print(f"Process filter override: {rep['process_filter']}")
    print()

    gs = rep["gpu_states"]
    if gs.get("available"):
        print("[GPU state utilization]")
        print(f"Rows: {gs['rows']}")
        print(f"Active: {_ns_fmt(gs['active_ns'])} ({gs['active_ratio'] * 100:.1f}%)")
        print(f"Idle:   {_ns_fmt(gs['idle_ns'])} ({gs['idle_ratio'] * 100:.1f}%)")
        for st, ns in gs["by_state_ns"].items():
            print(f"  - {st}: {_ns_fmt(ns)}")
    else:
        print(f"[GPU state utilization] unavailable: {gs.get('reason', 'unknown')}")
    print()

    ai = rep["app_intervals"]
    if ai.get("available"):
        print("[Metal application intervals (target process)]")
        print(f"Rows: {ai['target_rows']}, total: {_ns_fmt(ai['target_total_ns'])}")
        cb = ai["command_buffers"]
        print(
            "Command buffers: "
            f"count={cb.get('count', 0)}, total={_ns_fmt(cb.get('total_ns', 0))}, "
            f"share={cb.get('share_of_target_ns', 0.0) * 100:.1f}%"
        )
        if cb.get("count", 0) > 0:
            print(
                "  durations: "
                f"avg={_ns_fmt(cb['avg_ns'])}, median={_ns_fmt(cb['median_ns'])}, "
                f"p95={_ns_fmt(cb['p95_ns'])}, min={_ns_fmt(cb['min_ns'])}, max={_ns_fmt(cb['max_ns'])}"
            )
        if ai.get("depth_counts"):
            print("  by depth:")
            for depth, cnt in sorted(ai["depth_counts"].items(), key=lambda kv: kv[0]):
                ns = ai["depth_ns"].get(depth, 0)
                print(f"    depth {depth}: count={cnt}, total={_ns_fmt(ns)}")
    else:
        print(f"[Metal application intervals] unavailable: {ai.get('reason', 'unknown')}")
    print()

    gi = rep["gpu_intervals"]
    if gi.get("available"):
        print("[Metal GPU intervals ownership]")
        print(
            f"Rows={gi['rows']}, total={_ns_fmt(gi['all_ns'])}, "
            f"target={_ns_fmt(gi['target_ns'])} ({gi['target_share'] * 100:.1f}%)"
        )
        print("Top GPU interval owners:")
        for proc, ns in gi["top_processes"]:
            share = (ns / gi["all_ns"] * 100.0) if gi["all_ns"] > 0 else 0.0
            print(f"  - {proc}: {_ns_fmt(ns)} ({share:.1f}%)")
    else:
        print(f"[Metal GPU intervals] unavailable: {gi.get('reason', 'unknown')}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Analyze GPU-centric metrics from Instruments Metal System Trace")
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
