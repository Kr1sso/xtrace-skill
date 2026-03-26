#!/usr/bin/env python3
"""trace-analyze.py — Analyze macOS Instruments .trace files from the command line.

Subcommands:
  summary    Flat profile of hottest functions
  timeline   Time-bucketed analysis with phase detection
  calltree   Indented call tree
  collapsed  Collapsed stacks format (for flamegraph tools)
  flamegraph Generate interactive SVG flamegraph
  diff       Compare two profile summaries

Requires: xctrace (from Xcode) for trace export.
No external Python dependencies — stdlib only.
"""

import xml.etree.ElementTree as ET
import json
import argparse
import sys
import os
import subprocess
import re
import math
import textwrap
from collections import Counter, defaultdict, OrderedDict
from datetime import datetime
from typing import List, Dict, Tuple, Optional, Any, NamedTuple

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

class Sample:
    """A single time-profile or time-sample row."""
    __slots__ = (
        'time_ns', 'thread_fmt', 'thread_id', 'process_fmt', 'process_pid',
        'core_fmt', 'state', 'weight_ns', 'frames',
    )

    def __init__(self, time_ns, thread_fmt, thread_id, process_fmt, process_pid,
                 core_fmt, state, weight_ns, frames):
        self.time_ns = time_ns            # int – nanoseconds from trace start
        self.thread_fmt = thread_fmt      # str – e.g. 'Main Thread 0x21bc537'
        self.thread_id = thread_id        # str – tid hex string
        self.process_fmt = process_fmt    # str – e.g. 'yes (73196)'
        self.process_pid = process_pid    # str – PID
        self.core_fmt = core_fmt          # str – e.g. 'CPU 12 (P Core)'
        self.state = state                # str – Running / Blocked / …
        self.weight_ns = weight_ns        # int – sample weight in nanoseconds
        self.frames = frames              # list[(func_name, binary_name)] leaf-first


class ProfileEntry(NamedTuple):
    function: str
    module: str
    self_count: int
    total_count: int
    self_pct: float
    total_pct: float


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SPARKS = '▁▂▃▄▅▆▇█'

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

def _ns(text):
    """Try to interpret *text* as an integer nanosecond value."""
    try:
        return int(text.strip())
    except (ValueError, TypeError, AttributeError):
        return 0


def _fmt(elem):
    """Return the 'fmt' attribute of an element, or its text, or ''."""
    if elem is None:
        return ''
    f = elem.get('fmt', '')
    if f:
        return f
    return (elem.text or '').strip()


def parse_duration_ns(s):
    """Parse a human duration string to nanoseconds.

    Accepts: '1ms', '10ms', '500ms', '1s', '2.5s', '100us', plain number (seconds).
    """
    s = s.strip().lower()
    m = re.match(r'^([0-9]*\.?[0-9]+)\s*(s|ms|us|ns)?$', s)
    if not m:
        raise ValueError(f"Cannot parse duration: {s!r}")
    val = float(m.group(1))
    unit = m.group(2) or 's'
    multipliers = {'ns': 1, 'us': 1_000, 'ms': 1_000_000, 's': 1_000_000_000}
    return int(val * multipliers[unit])


def parse_time_range(time_range_str):
    """Parse a time range like '2.5s-3.0s' or '100ms-500ms' or '1s-'.

    Returns (start_ns, end_ns).  end_ns == -1 means unbounded.
    """
    parts = time_range_str.split('-', 1)
    if len(parts) != 2:
        raise ValueError(f"Time range must contain '-': {time_range_str!r}")
    start_str, end_str = parts[0].strip(), parts[1].strip()
    start_ns = parse_duration_ns(start_str) if start_str else 0
    end_ns = parse_duration_ns(end_str) if end_str else -1
    return start_ns, end_ns


def filter_samples(samples, process=None, thread=None, module=None, time_range=None):
    """Apply optional filters to a list of Sample objects."""
    filtered = samples
    if process:
        pl = process.lower()
        filtered = [s for s in filtered if pl in s.process_fmt.lower()]
    if thread:
        tl = thread.lower()
        filtered = [s for s in filtered if tl in s.thread_fmt.lower()]
    if module:
        ml = module.lower()
        filtered = [s for s in filtered
                    if any(ml in mod.lower() for _, mod in s.frames)]
    if time_range:
        start_ns, end_ns = parse_time_range(time_range)
        filtered = [s for s in filtered
                    if s.time_ns >= start_ns and (end_ns < 0 or s.time_ns <= end_ns)]
    return filtered


def _spark(value, max_value):
    """Return a single sparkline character for *value* relative to *max_value*."""
    if max_value <= 0:
        return SPARKS[0]
    idx = min(len(SPARKS) - 1, int(value / max_value * (len(SPARKS) - 1)))
    return SPARKS[idx]


def _fmt_ns_as_time(ns):
    """Format nanoseconds as a short human-readable time string."""
    if ns < 1_000_000:
        return f"{ns / 1_000:.0f}µs"
    if ns < 1_000_000_000:
        return f"{ns / 1_000_000:.1f}ms"
    return f"{ns / 1_000_000_000:.2f}s"


def _fmt_sec(ns):
    """Format nanoseconds as seconds with 2 decimal places."""
    return f"{ns / 1_000_000_000:.2f}s"


def _truncate(s, maxlen):
    """Truncate string *s* to *maxlen*, adding '…' if needed."""
    if len(s) <= maxlen:
        return s
    return s[:maxlen - 1] + '…'


def _count_unsymbolicated(samples):
    """Count leaf frames that look like raw hex addresses."""
    count = 0
    for s in samples:
        if s.frames:
            name = s.frames[0][0]
            if re.match(r'^0x[0-9a-fA-F]+$', name):
                count += 1
    return count


# ---------------------------------------------------------------------------
# XML trace parser
# ---------------------------------------------------------------------------

class TraceParser:
    """Parse xctrace-exported XML with full id/ref/sentinel resolution."""

    def __init__(self):
        self.id_registry = {}        # id_str -> parsed data (varies by type)
        self.trace_info = {}         # metadata extracted from TOC
        self.samples = []            # parsed Sample list

    # -- public API --------------------------------------------------------

    def parse_trace(self, trace_path, schema='time-profile'):
        """Export and parse a .trace bundle. Returns list[Sample]."""
        if not os.path.exists(trace_path):
            raise FileNotFoundError(f"Trace file not found: {trace_path}")

        # 1. TOC
        toc_xml = self._run_xctrace(trace_path, toc=True)
        self._parse_toc(toc_xml)

        # 2. Try requested schema, fall back
        schemas_to_try = [schema]
        if schema == 'time-profile':
            schemas_to_try.append('time-sample')
        elif schema == 'time-sample':
            schemas_to_try.append('time-profile')

        last_err = None
        for sch in schemas_to_try:
            xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{sch}"]'
            try:
                data_xml = self._run_xctrace(trace_path, xpath=xpath)
                if sch == 'time-sample':
                    return self._parse_rows(data_xml, backtrace_tag='kperf-bt')
                return self._parse_rows(data_xml, backtrace_tag='backtrace')
            except Exception as e:
                last_err = e
                continue

        raise RuntimeError(
            f"Failed to export trace data. Last error: {last_err}\n"
            "Check that the .trace file contains a Time Profiler or time-sample table."
        )

    # -- xctrace subprocess ------------------------------------------------

    @staticmethod
    def _run_xctrace(trace_path, toc=False, xpath=None):
        cmd = ['xctrace', 'export', '--input', trace_path]
        if toc:
            cmd.append('--toc')
        elif xpath:
            cmd.extend(['--xpath', xpath])
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError(
                f"xctrace export failed (exit {result.returncode}):\n{result.stderr.strip()}"
            )
        return result.stdout

    # -- TOC parsing -------------------------------------------------------

    def _parse_toc(self, xml_str):
        root = ET.fromstring(xml_str)
        info = {}

        # Duration
        dur = root.find('.//summary/duration')
        if dur is not None and dur.text:
            info['duration_s'] = float(dur.text.strip())

        # Template
        tmpl = root.find('.//summary/template-name')
        if tmpl is not None and tmpl.text:
            info['template'] = tmpl.text.strip()

        # Dates
        sd = root.find('.//summary/start-date')
        if sd is not None and sd.text:
            info['start_date'] = sd.text.strip()
        ed = root.find('.//summary/end-date')
        if ed is not None and ed.text:
            info['end_date'] = ed.text.strip()

        # Process
        proc = root.find('.//target/process')
        if proc is not None:
            info['process_name'] = proc.get('name', '')
            info['process_pid'] = proc.get('pid', '')

        # Device
        dev = root.find('.//target/device')
        if dev is not None:
            info['device_name'] = dev.get('name', '')
            info['device_model'] = dev.get('model', '')
            info['os_version'] = dev.get('os-version', '')

        # Available schemas
        schemas = []
        for tbl in root.findall('.//data/table'):
            sch = tbl.get('schema', '')
            if sch:
                schemas.append(sch)
        info['schemas'] = schemas

        self.trace_info = info

    # -- Row parsing (time-profile & time-sample) --------------------------

    def _parse_rows(self, xml_str, backtrace_tag='backtrace'):
        """Parse <row> elements from an xctrace data export."""
        root = ET.fromstring(xml_str)
        samples = []
        prev_values = {}  # col_index -> resolved value

        for node in root.iter('node'):
            for row in node.findall('row'):
                children = list(row)
                col_values = {}
                for i, child in enumerate(children):
                    if child.tag == 'sentinel':
                        col_values[i] = prev_values.get(i)
                    else:
                        col_values[i] = self._resolve_column(child, backtrace_tag)
                        prev_values[i] = col_values[i]

                sample = self._build_sample(col_values, backtrace_tag)
                if sample is not None:
                    samples.append(sample)

        self.samples = samples
        return samples

    def _resolve_column(self, elem, backtrace_tag='backtrace'):
        """Resolve a top-level column element (may have ref/id)."""
        ref = elem.get('ref')
        if ref and ref in self.id_registry:
            return self.id_registry[ref]

        tag = elem.tag
        eid = elem.get('id')

        # Backtrace / kperf-bt: list of frames
        if tag in ('backtrace', 'kperf-bt'):
            data = self._parse_backtrace(elem, tag)
            if eid:
                self.id_registry[eid] = data
            return data

        # Compound elements (thread, process): return dict
        if tag in ('thread', 'process'):
            data = self._parse_compound(elem)
            if eid:
                self.id_registry[eid] = data
            return data

        # Simple scalar elements (sample-time, core, thread-state, weight)
        data = self._parse_scalar(elem)
        if eid:
            self.id_registry[eid] = data
        return data

    def _parse_scalar(self, elem):
        """Parse a simple element with optional fmt, text, and id."""
        return {
            'tag': elem.tag,
            'fmt': elem.get('fmt', ''),
            'text': (elem.text or '').strip(),
            'id': elem.get('id', ''),
        }

    def _parse_compound(self, elem):
        """Parse thread or process element with nested children."""
        data = {
            'tag': elem.tag,
            'fmt': elem.get('fmt', ''),
            'text': (elem.text or '').strip(),
            'id': elem.get('id', ''),
        }
        # Extract nested elements (tid, process, pid, device-session)
        for child in elem:
            cid = child.get('id')
            cref = child.get('ref')
            if cref and cref in self.id_registry:
                child_data = self.id_registry[cref]
            else:
                child_data = self._parse_compound(child) if len(child) > 0 else self._parse_scalar(child)
                if cid:
                    self.id_registry[cid] = child_data

            # Attach well-known children
            if child.tag == 'tid':
                data['tid'] = child_data.get('fmt', '') or child_data.get('text', '')
            elif child.tag == 'pid':
                data['pid'] = child_data.get('fmt', '') or child_data.get('text', '')
            elif child.tag == 'process':
                data['process'] = child_data
                if 'pid' in child_data:
                    data['pid'] = child_data['pid']
            elif child.tag not in ('device-session',):
                data[child.tag] = child_data

        return data

    # -- Backtrace parsing -------------------------------------------------

    def _parse_backtrace(self, bt_elem, tag='backtrace'):
        """Parse a <backtrace> or <kperf-bt> element into a list of frames."""
        if tag == 'kperf-bt':
            return self._parse_kperf_bt(bt_elem)

        frames = []
        for child in bt_elem:
            if child.tag == 'frame':
                frame = self._parse_frame(child)
                frames.append(frame)
        return frames  # leaf-first order as in XML

    def _parse_frame(self, frame_elem):
        """Parse a single <frame> element, resolving refs."""
        ref = frame_elem.get('ref')
        if ref and ref in self.id_registry:
            return self.id_registry[ref]

        name = frame_elem.get('name', '<unknown>')
        binary_name = ''

        binary_elem = frame_elem.find('binary')
        if binary_elem is not None:
            bref = binary_elem.get('ref')
            if bref and bref in self.id_registry:
                binary_name = self.id_registry[bref]
            else:
                binary_name = binary_elem.get('name', '')
                bid = binary_elem.get('id')
                if bid:
                    self.id_registry[bid] = binary_name

        result = (name, binary_name)
        fid = frame_elem.get('id')
        if fid:
            self.id_registry[fid] = result
        return result

    def _parse_kperf_bt(self, bt_elem):
        """Parse a <kperf-bt> element (address-only backtrace)."""
        frames = []
        for child in bt_elem:
            if child.tag == 'text-address':
                addr_fmt = child.get('fmt', '')
                if not addr_fmt:
                    addr_fmt = '0x{:x}'.format(int(child.text.strip())) if child.text else '<unknown>'
                frames.append((addr_fmt, ''))
                cid = child.get('id')
                if cid:
                    self.id_registry[cid] = (addr_fmt, '')
        # If we got nothing from text-address, try the bt fmt itself
        if not frames:
            fmt = bt_elem.get('fmt', '')
            m = re.search(r'PC:(0x[0-9a-fA-F]+)', fmt)
            if m:
                frames.append((m.group(1), ''))
        return frames

    # -- Sample construction -----------------------------------------------

    def _build_sample(self, col_values, backtrace_tag='backtrace'):
        """Construct a Sample from the column dict.

        Expected column order for time-profile:
          0: sample-time  1: thread  2: process  3: core
          4: thread-state  5: weight  6: backtrace

        For time-sample the order may differ slightly, so we detect by type.
        """
        # Identify columns by tag
        time_val = None
        thread_val = None
        process_val = None
        core_val = None
        state_val = None
        weight_val = None
        frames = None

        for _i, val in sorted(col_values.items()):
            if val is None:
                continue
            # frames list
            if isinstance(val, list):
                frames = val
                continue
            if not isinstance(val, dict):
                continue
            tag = val.get('tag', '')
            if tag == 'sample-time':
                time_val = val
            elif tag == 'thread':
                thread_val = val
            elif tag == 'process':
                process_val = val
            elif tag == 'core':
                core_val = val
            elif tag == 'thread-state':
                state_val = val
            elif tag == 'weight':
                weight_val = val

        # Must have at least time + frames to be useful
        if time_val is None:
            return None
        if not frames:
            return None

        # Extract scalars
        time_ns = _ns(time_val.get('text', '0'))
        thread_fmt = (thread_val or {}).get('fmt', '')
        thread_id = (thread_val or {}).get('tid', '')
        process_fmt = (process_val or {}).get('fmt', '')
        if not process_fmt and thread_val and 'process' in thread_val:
            process_fmt = thread_val['process'].get('fmt', '')
        process_pid = (process_val or {}).get('pid', '')
        if not process_pid and thread_val and 'process' in thread_val:
            process_pid = thread_val['process'].get('pid', '')
        core_fmt = (core_val or {}).get('fmt', '')
        state = (state_val or {}).get('fmt', '')
        weight_ns = _ns((weight_val or {}).get('text', '0'))
        if weight_ns == 0:
            weight_ns = 1_000_000  # default 1ms if missing

        return Sample(
            time_ns=time_ns,
            thread_fmt=thread_fmt,
            thread_id=thread_id,
            process_fmt=process_fmt,
            process_pid=process_pid,
            core_fmt=core_fmt,
            state=state,
            weight_ns=weight_ns,
            frames=frames,
        )


# ---------------------------------------------------------------------------
# Subcommand: summary
# ---------------------------------------------------------------------------

def cmd_summary(args):
    """Flat profile of hottest functions."""
    parser = TraceParser()
    samples = parser.parse_trace(args.trace)
    samples = filter_samples(
        samples,
        process=getattr(args, 'process', None),
        thread=getattr(args, 'thread', None),
        module=getattr(args, 'module', None),
        time_range=getattr(args, 'time_range', None),
    )

    if not samples:
        print("No samples match the filter criteria.", file=sys.stderr)
        sys.exit(1)

    total = len(samples)

    # Compute flat profile
    self_counts = Counter()   # (func, mod) -> count
    total_counts = Counter()  # (func, mod) -> count
    module_self = Counter()   # mod -> count

    for s in samples:
        if not s.frames:
            continue
        # Leaf frame = self
        leaf_func, leaf_mod = s.frames[0]
        self_counts[(leaf_func, leaf_mod)] += 1
        module_self[leaf_mod] += 1
        # All frames = total
        seen = set()
        for func, mod in s.frames:
            key = (func, mod)
            if key not in seen:
                total_counts[key] += 1
                seen.add(key)

    # Build ProfileEntry list
    entries = []
    for (func, mod), sc in self_counts.items():
        tc = total_counts.get((func, mod), sc)
        entries.append(ProfileEntry(
            function=func,
            module=mod,
            self_count=sc,
            total_count=tc,
            self_pct=sc / total * 100,
            total_pct=tc / total * 100,
        ))

    sort_key = (lambda e: e.self_count) if args.by == 'self' else (lambda e: e.total_count)
    entries.sort(key=sort_key, reverse=True)
    entries = entries[:args.top]

    # Module summary
    mod_entries = []
    for mod, cnt in module_self.most_common():
        mod_entries.append((mod or '<unknown>', cnt, cnt / total * 100))

    # Unsymbolicated count
    unsym = _count_unsymbolicated(samples)

    # JSON output
    if args.json:
        data = {
            'trace_file': args.trace,
            'duration_s': parser.trace_info.get('duration_s', 0),
            'total_samples': total,
            'template': parser.trace_info.get('template', ''),
            'functions': [
                {
                    'function': e.function,
                    'module': e.module,
                    'self_count': e.self_count,
                    'self_pct': round(e.self_pct, 2),
                    'total_count': e.total_count,
                    'total_pct': round(e.total_pct, 2),
                }
                for e in entries
            ],
            'modules': [
                {'module': m, 'self_count': c, 'self_pct': round(p, 2)}
                for m, c, p in mod_entries
            ],
        }
        if unsym:
            data['unsymbolicated_frames'] = unsym
        json.dump(data, sys.stdout, indent=2)
        print()
        return

    # Text output
    dur = parser.trace_info.get('duration_s', 0)
    tmpl = parser.trace_info.get('template', 'Unknown')
    print(f"Trace: {args.trace}")
    print(f"Duration: {dur:.2f}s | Samples: {total} | Template: {tmpl}")
    if unsym:
        print(f"  ⚠  {unsym} unsymbolicated frames detected. Build with -g for function names.")
    print()

    # Function table
    hdr = f"{'Samples':>8}  {'Self%':>6}  {'Total%':>6}  {'Function':<40}  {'Module'}"
    print(hdr)
    print('─' * len(hdr))
    for e in entries:
        func_display = _truncate(e.function, 40)
        mod_display = _truncate(e.module or '<unknown>', 24)
        print(f"{e.self_count:>8}  {e.self_pct:>5.1f}%  {e.total_pct:>5.1f}%  {func_display:<40}  {mod_display}")

    # Module summary
    print()
    mhdr = f"{'Samples':>8}  {'%':>6}  {'Module'}"
    print(mhdr)
    print('─' * len(mhdr))
    for mod, cnt, pct in mod_entries[:15]:
        print(f"{cnt:>8}  {pct:>5.1f}%  {_truncate(mod, 40)}")


# ---------------------------------------------------------------------------
# Subcommand: timeline
# ---------------------------------------------------------------------------

def cmd_timeline(args):
    """Time-bucketed analysis with optional phase detection."""
    parser = TraceParser()
    samples = parser.parse_trace(args.trace)
    samples = filter_samples(
        samples,
        process=getattr(args, 'process', None),
        thread=getattr(args, 'thread', None),
        time_range=getattr(args, 'time_range', None),
    )

    if not samples:
        print("No samples match the filter criteria.", file=sys.stderr)
        sys.exit(1)

    total = len(samples)
    window_ns = parse_duration_ns(args.window)
    top_n = args.top

    # Time bounds
    min_time = min(s.time_ns for s in samples)
    max_time = max(s.time_ns for s in samples)

    # Bucket samples
    buckets = defaultdict(list)  # bucket_index -> [Sample]
    for s in samples:
        idx = (s.time_ns - min_time) // window_ns
        buckets[idx].append(s)

    max_idx = max(buckets.keys()) if buckets else 0
    bucket_counts = [len(buckets.get(i, [])) for i in range(max_idx + 1)]
    max_count = max(bucket_counts) if bucket_counts else 1
    median_count = sorted(bucket_counts)[len(bucket_counts) // 2] if bucket_counts else 0

    # Build bucket data
    bucket_data = []
    for i in range(max_idx + 1):
        bsamples = buckets.get(i, [])
        count = len(bsamples)
        start_ns = min_time + i * window_ns
        end_ns = start_ns + window_ns

        # Top functions by self-count
        func_counter = Counter()
        for s in bsamples:
            if s.frames:
                func_counter[s.frames[0][0]] += 1
        top_funcs = func_counter.most_common(top_n)

        # Confidence
        if count < 20:
            conf = 'low'
        elif count < 50:
            conf = 'med'
        else:
            conf = 'high'

        # Spike detection
        is_spike = count > 2 * median_count if median_count > 0 else False

        bucket_data.append({
            'index': i,
            'start_ns': start_ns,
            'end_ns': end_ns,
            'count': count,
            'confidence': conf,
            'is_spike': is_spike,
            'top_functions': top_funcs,
        })

    # Phase detection (adaptive mode)
    phases = []
    if args.adaptive:
        phases = _detect_phases(bucket_data, window_ns, min_time)

    # JSON output
    if args.json:
        data = {
            'trace_file': args.trace,
            'duration_s': parser.trace_info.get('duration_s', 0),
            'total_samples': total,
            'window_ns': window_ns,
            'window_str': args.window,
            'buckets': [
                {
                    'start_s': round(b['start_ns'] / 1e9, 4),
                    'end_s': round(b['end_ns'] / 1e9, 4),
                    'samples': b['count'],
                    'confidence': b['confidence'],
                    'is_spike': b['is_spike'],
                    'top_functions': [
                        {'function': f, 'count': c, 'pct': round(c / b['count'] * 100, 1) if b['count'] else 0}
                        for f, c in b['top_functions']
                    ],
                }
                for b in bucket_data
            ],
        }
        if phases:
            data['phases'] = [
                {
                    'phase': i + 1,
                    'start_s': round(p['start_ns'] / 1e9, 4),
                    'end_s': round(p['end_ns'] / 1e9, 4),
                    'label': p['label'],
                    'description': p['description'],
                }
                for i, p in enumerate(phases)
            ]
        json.dump(data, sys.stdout, indent=2)
        print()
        return

    # Text output
    dur = parser.trace_info.get('duration_s', 0)
    print(f"Trace: {args.trace} | Duration: {dur:.2f}s | Window: {args.window}")
    print()

    time_w = 18
    hdr = f"{'Time':<{time_w}}  {'Samples':>7}  Conf  Spark  Top Functions"
    print(hdr)
    print('─' * 78)

    for b in bucket_data:
        t_start = _fmt_sec(b['start_ns'])
        t_end = _fmt_sec(b['end_ns'])
        time_str = f"{t_start}–{t_end}"

        conf_str = {'low': '░░', 'med': '▓░', 'high': '██'}.get(b['confidence'], '  ')
        spark = _spark(b['count'], max_count)

        top_str = ', '.join(
            f"{f} ({c / b['count'] * 100:.0f}%)" if b['count'] else f
            for f, c in b['top_functions'][:3]
        )
        top_str = _truncate(top_str, 40)

        spike_marker = '  ← SPIKE' if b['is_spike'] else ''

        print(f"{time_str:<{time_w}}  {b['count']:>7}  {conf_str}    {spark}     {top_str}{spike_marker}")

    # Phase summary
    if phases:
        print()
        print("=== PHASE DETECTION ===")
        for i, p in enumerate(phases):
            s = _fmt_sec(p['start_ns'])
            e = _fmt_sec(p['end_ns'])
            print(f"Phase {i+1}:  {s}–{e}  \"{p['label']}\"  ({p['description']})")


def _detect_phases(bucket_data, window_ns, min_time):
    """Auto-detect phases by measuring Jaccard similarity between adjacent buckets."""
    if not bucket_data:
        return []

    # Get top-5 function sets per bucket
    def top_set(b):
        return set(f for f, _ in b['top_functions'][:5])

    def jaccard(a, b):
        if not a and not b:
            return 1.0
        if not a or not b:
            return 0.0
        return len(a & b) / len(a | b)

    # Find boundaries where Jaccard < 0.4
    boundaries = [0]
    for i in range(1, len(bucket_data)):
        j = jaccard(top_set(bucket_data[i - 1]), top_set(bucket_data[i]))
        if j < 0.4:
            boundaries.append(i)
    boundaries.append(len(bucket_data))

    # Build phases
    startup_keywords = {'dyld', 'objc', '_init', 'initialize', 'dlopen', 'ImageLoader',
                        'prepare', 'setup', 'configure', 'bootstrap', 'load'}
    gc_keywords = {'gc', 'GC', 'collect', 'sweep', 'mark', 'scavenge', 'garbage',
                   'finalize', 'release_pool', 'autorelease'}
    io_keywords = {'read', 'write', 'recv', 'send', 'poll', 'select', 'kevent',
                   'io_poll', 'stream_io', 'socket', 'fsync', 'pread', 'pwrite'}
    alloc_keywords = {'malloc', 'calloc', 'realloc', 'free', 'xzm_', 'mmap',
                      'allocat', 'dealloc', 'szone_', 'nano_', 'new', 'delete'}

    phases = []
    for bi in range(len(boundaries) - 1):
        start_idx = boundaries[bi]
        end_idx = boundaries[bi + 1]
        phase_buckets = bucket_data[start_idx:end_idx]

        start_ns = phase_buckets[0]['start_ns']
        end_ns = phase_buckets[-1]['end_ns']
        total_count = sum(b['count'] for b in phase_buckets)

        # Aggregate top functions
        func_counter = Counter()
        for b in phase_buckets:
            for f, c in b['top_functions']:
                func_counter[f] += c

        top_func = func_counter.most_common(1)[0][0] if func_counter else 'idle'
        top_pct = func_counter.most_common(1)[0][1] / total_count * 100 if total_count and func_counter else 0

        # Label heuristic — check what fraction of samples match each category
        top_names_lower = set(f.lower() for f in func_counter)
        all_names_str = ' '.join(top_names_lower)

        def keyword_score(keywords):
            return sum(1 for kw in keywords if any(kw in n for n in top_names_lower))

        scores = {
            'Startup': keyword_score(startup_keywords),
            'GC':      keyword_score(gc_keywords),
            'I/O':     keyword_score(io_keywords),
            'Alloc':   keyword_score(alloc_keywords),
        }

        # Check for idle (very few samples relative to bucket count)
        avg_samples_per_bucket = total_count / max(len(phase_buckets), 1)

        # Check for spikes
        max_bucket = max((b['count'] for b in phase_buckets), default=0)
        median_bucket = sorted(b['count'] for b in phase_buckets)[len(phase_buckets) // 2] if phase_buckets else 0

        if total_count == 0 or avg_samples_per_bucket < 3:
            label = 'Idle'
        elif max_bucket > 3 * median_bucket and len(phase_buckets) <= 3:
            # Short burst with very high sample count
            best_cat = max(scores, key=scores.get)
            if scores[best_cat] >= 2:
                label = f'{best_cat} Spike'
            else:
                label = 'CPU Spike'
        else:
            best_cat = max(scores, key=scores.get)
            if scores[best_cat] >= 2:
                label = best_cat
            else:
                label = 'Compute'

        desc = f"{top_func} at ~{top_pct:.0f}%"
        if total_count == 0:
            desc = 'no samples'

        phases.append({
            'start_ns': start_ns,
            'end_ns': end_ns,
            'label': label,
            'description': desc,
        })

    return phases


# ---------------------------------------------------------------------------
# Subcommand: calltree
# ---------------------------------------------------------------------------

class TrieNode:
    """Node in the call tree trie."""
    __slots__ = ('name', 'module', 'count', 'self_count', 'children')

    def __init__(self, name='', module=''):
        self.name = name
        self.module = module
        self.count = 0
        self.self_count = 0
        self.children = OrderedDict()


def cmd_calltree(args):
    """Indented call tree."""
    parser = TraceParser()
    samples = parser.parse_trace(args.trace)
    samples = filter_samples(
        samples,
        process=getattr(args, 'process', None),
        thread=getattr(args, 'thread', None),
        time_range=getattr(args, 'time_range', None),
    )

    if not samples:
        print("No samples match the filter criteria.", file=sys.stderr)
        sys.exit(1)

    total = len(samples)
    max_depth = args.depth
    min_pct = args.min_pct

    # Build trie (root-first traversal)
    root = TrieNode('<root>', '')
    root.count = total

    for s in samples:
        if not s.frames:
            continue
        frames = list(reversed(s.frames))  # root-first
        node = root
        for i, (func, mod) in enumerate(frames):
            if i >= max_depth:
                break
            key = (func, mod)
            if key not in node.children:
                node.children[key] = TrieNode(func, mod)
            node = node.children[key]
            node.count += 1
            if i == len(frames) - 1:
                node.self_count += 1

    # Print header
    dur = parser.trace_info.get('duration_s', 0)
    tmpl = parser.trace_info.get('template', 'Unknown')
    print(f"Trace: {args.trace}")
    print(f"Duration: {dur:.2f}s | Samples: {total} | Template: {tmpl}")
    print()

    # Recursive print
    _print_trie(root, total, min_pct, prefix='', is_last=True, is_root=True)


def _print_trie(node, total, min_pct, prefix='', is_last=True, is_root=False):
    """Recursively print a trie node with tree-drawing characters."""
    if not is_root:
        pct = node.count / total * 100 if total else 0
        if pct < min_pct:
            return

        connector = '└── ' if is_last else '├── '
        hot = '  ← HOT' if node.self_count > 0 and (node.self_count / total * 100) >= 10.0 else ''
        mod = _truncate(node.module or '', 20)
        func = _truncate(node.name, 40)
        line = f"{prefix}{connector}{pct:5.1f}%  {func:<40}  {mod}{hot}"
        print(line)

        prefix = prefix + ('    ' if is_last else '│   ')
    else:
        prefix = ''

    # Sort children by count descending, then filter before rendering
    # so that is_last is computed against the visible list (correct tree chars)
    sorted_children = sorted(node.children.values(), key=lambda c: c.count, reverse=True)
    visible_children = [c for c in sorted_children
                        if (c.count / total * 100 if total else 0) >= min_pct]
    for i, child in enumerate(visible_children):
        _print_trie(child, total, min_pct, prefix, is_last=(i == len(visible_children) - 1))


# ---------------------------------------------------------------------------
# Subcommand: collapsed
# ---------------------------------------------------------------------------

def cmd_collapsed(args):
    """Collapsed stacks format (for flamegraph tools)."""
    parser = TraceParser()
    samples = parser.parse_trace(args.trace)
    samples = filter_samples(
        samples,
        process=getattr(args, 'process', None),
        thread=getattr(args, 'thread', None),
        time_range=getattr(args, 'time_range', None),
    )

    if not samples:
        print("No samples match the filter criteria.", file=sys.stderr)
        sys.exit(1)

    include_module = args.include_module

    stacks = Counter()
    for s in samples:
        if not s.frames:
            continue
        frames = list(reversed(s.frames))  # root-first
        if include_module:
            parts = [f"{func} [{mod}]" if mod else func for func, mod in frames]
        else:
            parts = [func for func, _ in frames]
        stack_str = ';'.join(parts)
        stacks[stack_str] += 1

    for stack, count in stacks.most_common():
        print(f"{stack} {count}")


# ---------------------------------------------------------------------------
# Subcommand: flamegraph (built-in SVG generator)
# ---------------------------------------------------------------------------

class FlameNode:
    """Node in the flame trie for SVG generation."""
    __slots__ = ('name', 'module', 'self_value', 'total', 'children')

    def __init__(self, name='root', module=''):
        self.name = name
        self.module = module
        self.self_value = 0
        self.total = 0
        self.children = OrderedDict()


def cmd_flamegraph(args):
    """Generate an interactive SVG flamegraph."""
    parser = TraceParser()
    samples = parser.parse_trace(args.trace)
    samples = filter_samples(
        samples,
        process=getattr(args, 'process', None),
        thread=getattr(args, 'thread', None),
        time_range=getattr(args, 'time_range', None),
    )

    if not samples:
        print("No samples match the filter criteria.", file=sys.stderr)
        sys.exit(1)

    total = len(samples)

    # Build flame trie
    flame_root = FlameNode('all', '')
    flame_root.total = total

    for s in samples:
        if not s.frames:
            continue
        frames = list(reversed(s.frames))  # root-first
        node = flame_root
        for i, (func, mod) in enumerate(frames):
            key = (func, mod)  # distinguish same-named functions in different modules
            if key not in node.children:
                node.children[key] = FlameNode(func, mod)
            child = node.children[key]
            child.total += 1
            if i == len(frames) - 1:
                child.self_value += 1
            node = child

    # Compute max depth
    def max_depth(node, d=0):
        if not node.children:
            return d
        return max(max_depth(c, d + 1) for c in node.children.values())

    depth = max_depth(flame_root) + 1

    # Layout
    img_width = args.width
    row_height = 18
    top_margin = 50
    bottom_margin = 10
    img_height = top_margin + depth * row_height + bottom_margin

    color_by = args.color_by
    title = args.title

    rects = []  # [(name, module, x_frac, width_frac, depth, self_val, total)]

    def layout(node, x_frac, d):
        w_frac = node.total / total if total else 0
        if w_frac < 0.0001:
            return
        rects.append((node.name, node.module, x_frac, w_frac, d, node.self_value, node.total))
        child_x = x_frac
        # Sort children by total descending for visual stability
        sorted_kids = sorted(node.children.values(), key=lambda c: c.total, reverse=True)
        for child in sorted_kids:
            layout(child, child_x, d + 1)
            child_x += child.total / total if total else 0

    layout(flame_root, 0.0, 0)

    # Color functions
    def module_color(module_name):
        h = hash(module_name or '') % 360
        return f"hsl({h}, 70%, 60%)"

    def heat_color(pct):
        r = 255
        g = int(210 * (1 - min(pct, 100) / 100))
        b = int(50 * (1 - min(pct, 100) / 100))
        return f"rgb({r},{g},{b})"

    # Generate SVG
    svg_parts = []
    svg_parts.append(f'<svg xmlns="http://www.w3.org/2000/svg" '
                     f'width="{img_width}" height="{img_height}" '
                     f'viewBox="0 0 {img_width} {img_height}" '
                     f'font-family="monospace" font-size="11">')

    # Embedded CSS
    svg_parts.append('''<style>
  .frame rect { stroke-width: 0; }
  .frame rect:hover { stroke: #000; stroke-width: 0.5; cursor: pointer; }
  .frame text { pointer-events: none; fill: #000; dominant-baseline: central; }
  .frame-text { font-size: 11px; }
  .title { font-size: 16px; font-weight: bold; fill: #333; }
  .subtitle { font-size: 11px; fill: #666; }
  .background { fill: #f8f8f8; }
  .matched rect { stroke: #f0f; stroke-width: 1.5; }
</style>''')

    # Background
    svg_parts.append(f'<rect class="background" x="0" y="0" width="{img_width}" height="{img_height}" '
                     f'id="bg" />')

    # Title
    svg_parts.append(f'<text class="title" x="10" y="20">{_svg_escape(title)}</text>')
    dur = parser.trace_info.get('duration_s', 0)
    svg_parts.append(
        f'<text class="subtitle" x="10" y="36">'
        f'{total} samples | {dur:.2f}s | color by {color_by}</text>')

    # Frames
    for name, module, x_frac, w_frac, d, self_val, tot in rects:
        x = x_frac * img_width
        w = w_frac * img_width
        if w < 0.5:
            continue  # too narrow to render
        # Standard flamegraph: root at bottom, leaf at top
        y = img_height - bottom_margin - (d + 1) * row_height

        pct = tot / total * 100 if total else 0
        if color_by == 'module':
            fill = module_color(module)
        else:
            fill = heat_color(pct)

        tooltip = f"{_svg_escape(name)} ({module})\n{tot} samples ({pct:.1f}%)"
        if self_val:
            tooltip += f"\nself: {self_val} ({self_val / total * 100:.1f}%)"

        svg_parts.append(f'<g class="frame">')
        svg_parts.append(f'  <title>{tooltip}</title>')
        svg_parts.append(f'  <rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{row_height - 1}" '
                         f'fill="{fill}" rx="1" />')
        # Only render text if frame is wide enough
        if w > 30:
            max_chars = int(w / 7)
            display_name = _truncate(name, max_chars)
            tx = x + 2
            ty = y + row_height / 2
            svg_parts.append(
                f'  <text class="frame-text" x="{tx:.1f}" y="{ty:.0f}">'
                f'{_svg_escape(display_name)}</text>')
        svg_parts.append('</g>')

    # Interactive JavaScript
    svg_parts.append('''<script type="text/ecmascript"><![CDATA[
(function() {
  var svg = document.querySelector("svg");
  var frames = document.querySelectorAll(".frame");
  var bg = document.getElementById("bg");
  
  // Click to zoom
  frames.forEach(function(g) {
    g.addEventListener("click", function(e) {
      e.stopPropagation();
      var rect = g.querySelector("rect");
      var rx = parseFloat(rect.getAttribute("x"));
      var rw = parseFloat(rect.getAttribute("width"));
      var svgW = parseFloat(svg.getAttribute("width"));
      if (rw < 1) return;
      var scale = svgW / rw;
      var tx = -rx * scale;
      frames.forEach(function(f) {
        var r = f.querySelector("rect");
        var ox = parseFloat(r.getAttribute("x"));
        var ow = parseFloat(r.getAttribute("width"));
        var nx = ox * scale + tx;
        var nw = ow * scale;
        r.setAttribute("x", nx);
        r.setAttribute("width", nw);
        var t = f.querySelector("text");
        if (t) {
          t.setAttribute("x", nx + 2);
          if (nw > 30) {
            t.style.display = "";
          } else {
            t.style.display = "none";
          }
        }
      });
    });
  });
  
  // Reset on background click
  bg.addEventListener("click", function() {
    location.reload();
  });

  // Keyboard search (Ctrl+F)
  document.addEventListener("keydown", function(e) {
    if ((e.ctrlKey || e.metaKey) && e.key === "f") {
      e.preventDefault();
      var term = prompt("Search frames:");
      if (!term) {
        frames.forEach(function(f) { f.classList.remove("matched"); });
        return;
      }
      var re = new RegExp(term, "i");
      frames.forEach(function(f) {
        var title = f.querySelector("title");
        if (title && re.test(title.textContent)) {
          f.classList.add("matched");
        } else {
          f.classList.remove("matched");
        }
      });
    }
  });
})();
]]></script>''')

    svg_parts.append('</svg>')

    svg_content = '\n'.join(svg_parts)

    output = args.output
    with open(output, 'w') as f:
        f.write(svg_content)

    print(f"Flamegraph written to {output}")
    print(f"  {total} samples | {depth} levels | {len(rects)} frames rendered")


def _svg_escape(s):
    """Escape text for safe SVG/XML embedding."""
    return (s.replace('&', '&amp;')
             .replace('<', '&lt;')
             .replace('>', '&gt;')
             .replace('"', '&quot;')
             .replace("'", '&apos;'))


# ---------------------------------------------------------------------------
# Subcommand: diff
# ---------------------------------------------------------------------------

def cmd_diff(args):
    """Compare two profile summaries (JSON from summary --json)."""
    with open(args.before) as f:
        before = json.load(f)
    with open(args.after) as f:
        after = json.load(f)

    threshold = args.threshold

    # Build maps: (function, module) -> {self_pct, total_pct}
    def build_map(data):
        m = {}
        for entry in data.get('functions', []):
            key = (entry['function'], entry.get('module', ''))
            m[key] = {
                'self_pct': entry.get('self_pct', 0),
                'total_pct': entry.get('total_pct', 0),
            }
        return m

    before_map = build_map(before)
    after_map = build_map(after)

    all_keys = set(before_map.keys()) | set(after_map.keys())

    improved = []
    regressed = []
    unchanged = []
    new_funcs = []
    gone_funcs = []

    for key in all_keys:
        b = before_map.get(key)
        a = after_map.get(key)
        func, mod = key

        if b is None:
            new_funcs.append((func, mod, a['self_pct'], a['total_pct']))
        elif a is None:
            gone_funcs.append((func, mod, b['self_pct'], b['total_pct']))
        else:
            self_delta = a['self_pct'] - b['self_pct']
            total_delta = a['total_pct'] - b['total_pct']
            # Classify by self_pct change (primary indicator), but show both
            if self_delta < -threshold:
                improved.append((func, mod, b['self_pct'], a['self_pct'], self_delta,
                                 b['total_pct'], a['total_pct'], total_delta))
            elif self_delta > threshold:
                regressed.append((func, mod, b['self_pct'], a['self_pct'], self_delta,
                                  b['total_pct'], a['total_pct'], total_delta))
            else:
                unchanged.append((func, mod, b['self_pct'], a['self_pct'], self_delta,
                                  b['total_pct'], a['total_pct'], total_delta))

    # Sort
    improved.sort(key=lambda x: x[4])      # most improved first (most negative)
    regressed.sort(key=lambda x: -x[4])    # most regressed first
    new_funcs.sort(key=lambda x: -x[2])
    gone_funcs.sort(key=lambda x: -x[2])

    # Print
    b_samples = before.get('total_samples', 0)
    a_samples = after.get('total_samples', 0)
    print(f"=== PERFORMANCE DIFF: baseline → optimized ===")
    print(f"Baseline: {b_samples} samples | Optimized: {a_samples} samples")
    print()

    if improved:
        print("IMPROVED ↓ (less CPU time):")
        print(f"  {'Function':<36}  {'Self':>13}  {'Δself':>7}  {'Total':>14}  {'Δtotal':>8}")
        for func, mod, bs, as_, sd, bt, at, td in improved:
            f_display = _truncate(func, 36)
            print(f"  {f_display:<36}  {bs:>5.1f}→{as_:>5.1f}%  {sd:>+6.1f}%  {bt:>5.1f}→{at:>5.1f}%  {td:>+7.1f}%  ⬇")
        print()

    if regressed:
        print("REGRESSED ↑ (more CPU time):")
        print(f"  {'Function':<36}  {'Self':>13}  {'Δself':>7}  {'Total':>14}  {'Δtotal':>8}")
        for func, mod, bs, as_, sd, bt, at, td in regressed:
            f_display = _truncate(func, 36)
            print(f"  {f_display:<36}  {bs:>5.1f}→{as_:>5.1f}%  {sd:>+6.1f}%  {bt:>5.1f}→{at:>5.1f}%  {td:>+7.1f}%  ⬆")
        print()

    if new_funcs:
        print("NEW (only in optimized):")
        for func, mod, sp, tp in new_funcs[:10]:
            f_display = _truncate(func, 36)
            print(f"  {f_display:<36}     self: {sp:>5.1f}%  total: {tp:>5.1f}%  NEW")
        print()

    if gone_funcs:
        print("GONE (only in baseline):")
        for func, mod, sp, tp in gone_funcs[:10]:
            f_display = _truncate(func, 36)
            print(f"  {f_display:<36}     self: {sp:>5.1f}%  total: {tp:>5.1f}%  GONE")
        print()

    if unchanged:
        unc_count = len(unchanged)
        print(f"UNCHANGED (within ±{threshold:.1f}%): {unc_count} functions")
        # Show top 5
        unchanged.sort(key=lambda x: -max(x[2], x[3]))
        for func, mod, bs, as_, sd, bt, at, td in unchanged[:5]:
            f_display = _truncate(func, 36)
            print(f"  {f_display:<36}  {bs:>5.1f}→{as_:>5.1f}%  {sd:>+6.1f}%  {bt:>5.1f}→{at:>5.1f}%  {td:>+7.1f}%")
        if unc_count > 5:
            print(f"  ... and {unc_count - 5} more")


# ---------------------------------------------------------------------------
# CLI argument parser
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        prog='trace-analyze',
        description='Analyze macOS Instruments .trace files from the command line.',
        epilog='Examples:\n'
               '  trace-analyze.py summary my.trace --top 20\n'
               '  trace-analyze.py timeline my.trace --window 100ms --adaptive\n'
               '  trace-analyze.py calltree my.trace --depth 15 --min-pct 2\n'
               '  trace-analyze.py collapsed my.trace --with-module | flamegraph.pl > out.svg\n'
               '  trace-analyze.py flamegraph my.trace -o flame.svg --color-by module\n'
               '  trace-analyze.py diff before.json after.json --threshold 0.5\n',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest='command')

    # -- common filter args helper -----------------------------------------
    def add_filter_args(p):
        p.add_argument('--process', help='Filter by process name (substring match)')
        p.add_argument('--thread', help='Filter by thread name (substring match)')
        p.add_argument('--time-range', help='Time range, e.g. 2.5s-3.0s, 100ms-500ms, 1s-')

    # -- summary -----------------------------------------------------------
    p_summary = subparsers.add_parser('summary', help='Flat profile of hottest functions')
    p_summary.add_argument('trace', help='Path to .trace file')
    p_summary.add_argument('--top', type=int, default=30, help='Number of functions to show (default: 30)')
    p_summary.add_argument('--by', choices=['self', 'total'], default='self',
                           help='Sort by self or total samples (default: self)')
    p_summary.add_argument('--module', help='Filter by module/binary name (substring match)')
    p_summary.add_argument('--json', action='store_true', help='Output as JSON')
    add_filter_args(p_summary)

    # -- timeline ----------------------------------------------------------
    p_timeline = subparsers.add_parser('timeline', help='Time-bucketed analysis with optional phase detection')
    p_timeline.add_argument('trace', help='Path to .trace file')
    p_timeline.add_argument('--window', default='500ms',
                            help='Bucket size (e.g. 1ms, 10ms, 100ms, 500ms, 1s; default: 500ms)')
    p_timeline.add_argument('--adaptive', action='store_true',
                            help='Auto-detect phases using Jaccard similarity')
    p_timeline.add_argument('--min-window', default='10ms',
                            help='Minimum window for adaptive mode (default: 10ms)')
    p_timeline.add_argument('--top', type=int, default=5,
                            help='Top N functions per bucket (default: 5)')
    p_timeline.add_argument('--json', action='store_true', help='Output as JSON')
    add_filter_args(p_timeline)

    # -- calltree ----------------------------------------------------------
    p_calltree = subparsers.add_parser('calltree', help='Indented call tree')
    p_calltree.add_argument('trace', help='Path to .trace file')
    p_calltree.add_argument('--depth', type=int, default=10, help='Max tree depth (default: 10)')
    p_calltree.add_argument('--min-pct', type=float, default=1.0,
                            help='Prune branches below this %% (default: 1.0)')
    add_filter_args(p_calltree)

    # -- collapsed ---------------------------------------------------------
    p_collapsed = subparsers.add_parser('collapsed', help='Collapsed stacks format (for flamegraph tools)')
    p_collapsed.add_argument('trace', help='Path to .trace file')
    p_collapsed.add_argument('--with-module', action='store_true', dest='include_module',
                            help='Include [module] tags in output (e.g. "func [libfoo.dylib]")')
    # Keep --module as hidden alias for backwards compatibility
    p_collapsed.add_argument('--module', action='store_true', dest='include_module',
                            help=argparse.SUPPRESS)
    add_filter_args(p_collapsed)

    # -- flamegraph --------------------------------------------------------
    p_flame = subparsers.add_parser('flamegraph', help='Generate interactive SVG flamegraph')
    p_flame.add_argument('trace', help='Path to .trace file')
    p_flame.add_argument('-o', '--output', required=True, help='Output SVG path')
    p_flame.add_argument('--title', default='Flamegraph', help='Title shown in the SVG (default: Flamegraph)')
    p_flame.add_argument('--width', type=int, default=1200, help='SVG width in pixels (default: 1200)')
    p_flame.add_argument('--color-by', choices=['module', 'heat'], default='heat',
                         help='Color scheme: module (by binary) or heat (default: heat)')
    add_filter_args(p_flame)

    # -- diff --------------------------------------------------------------
    p_diff = subparsers.add_parser('diff', help='Compare two profile summaries (JSON from summary --json)')
    p_diff.add_argument('before', help='Baseline JSON file (from summary --json)')
    p_diff.add_argument('after', help='Optimized JSON file (from summary --json)')
    p_diff.add_argument('--threshold', type=float, default=1.0,
                        help='Change threshold in %% (default: 1.0)')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Support piping: trace ./app | trace-analyze summary -
    if hasattr(args, 'trace') and args.trace == '-':
        args.trace = sys.stdin.readline().strip()
        if not args.trace:
            print("Error: No trace path received on stdin.", file=sys.stderr)
            sys.exit(1)

    commands = {
        'summary': cmd_summary,
        'timeline': cmd_timeline,
        'calltree': cmd_calltree,
        'collapsed': cmd_collapsed,
        'flamegraph': cmd_flamegraph,
        'diff': cmd_diff,
    }

    try:
        commands[args.command](args)
    except KeyboardInterrupt:
        sys.exit(130)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON — {e}", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        if os.environ.get('TRACE_ANALYZE_DEBUG'):
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
