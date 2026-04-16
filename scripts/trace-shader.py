#!/usr/bin/env python3
"""trace-shader.py — analyze Metal shader-profiler traces from Instruments.

Subcommands:
  info       Show shader-profiler availability and metadata
  hotspots   Aggregate hottest shaders / callsites / PCs
  callsites  Print a tree of shader callsites / PCs
  collapsed  Emit collapsed stacks for flamegraph tools
  flamegraph Generate an interactive SVG shader flamegraph

The tool understands three tiers of shader data, automatically using the best
available source in this order:
  1. metal-shader-profiler-intervals   (high-level shader timeline rows)
  2. gpu-shader-profiler-interval      (per-PC duration rows)
  3. gpu-shader-profiler-sample        (per-sample PC stacks, when exported)

When callsite-level function names are unavailable, raw PC offsets are emitted
as frame labels (e.g. proceduralFragment+0x1a4).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter, OrderedDict, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, DefaultDict, Dict, Iterable, List, NamedTuple, Optional, Sequence, Tuple

SPARKS = '▁▂▃▄▅▆▇█'


@dataclass
class ShaderBinary:
    name: str
    label: str
    stage: str
    pso_name: str
    shader_id: int
    pc_start: int
    pc_end: int
    process: str
    timestamp_ns: int = 0

    @property
    def base_name(self) -> str:
        text = self.name or self.label or '<unknown-shader>'
        return re.sub(r'\s+\([0-9]+\)$', '', text).strip() or text.strip()


@dataclass
class ShaderInterval:
    time_ns: int
    duration_ns: int
    shader_name: str
    function_label: str
    pso_name: str
    shader_type: str
    channel_name: str
    process: str
    percent_of_kick: float = 0.0
    total_kick_percent: float = 0.0


@dataclass
class ShaderPCInterval:
    time_ns: int
    duration_ns: int
    pc: int
    submission_id: int
    datamaster: int
    shader: Optional[ShaderBinary]


@dataclass
class ShaderSample:
    time_ns: int
    pcs: List[int]
    stack_parts: List[str]
    leaf_label: str
    shader_name: str
    shader_type: str


@dataclass
class GPUIntervalFallback:
    time_ns: int
    duration_ns: int
    channel_name: str
    label: str
    process: str


@dataclass
class PSOInfo:
    label: str
    process: str
    pso_type: str
    vertex_id: Optional[int] = None
    fragment_id: Optional[int] = None
    tile_id: Optional[int] = None
    compute_id: Optional[int] = None
    mesh_id: Optional[int] = None
    object_id: Optional[int] = None


@dataclass
class ShaderTraceData:
    trace_path: str
    target_name: str
    target_pid: str
    process_filter: str
    shader_timeline_setting: Optional[bool]
    shader_binaries: List[ShaderBinary]
    shader_intervals: List[ShaderInterval]
    pc_intervals: List[ShaderPCInterval]
    samples: List[ShaderSample]
    gpu_interval_fallbacks: List[GPUIntervalFallback]
    pso_infos: List[PSOInfo]
    signpost_rows: int
    sample_rows: int
    pc_interval_rows: int
    interval_rows: int


class FlameNode:
    __slots__ = ('name', 'self_value', 'total', 'children')

    def __init__(self, name: str = 'root'):
        self.name = name
        self.self_value = 0
        self.total = 0
        self.children: OrderedDict[str, 'FlameNode'] = OrderedDict()


# ---------------------------------------------------------------------------
# Low-level XML / xctrace helpers
# ---------------------------------------------------------------------------


def _run(cmd: Sequence[str]) -> str:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{proc.stderr.strip()}")
    return proc.stdout


def _parse_xml(text: str) -> ET.Element:
    try:
        return ET.fromstring(text)
    except ET.ParseError as exc:
        raise RuntimeError(f"failed to parse xctrace XML export: {exc}")


def _export_toc_text(trace_path: str) -> str:
    return _run(["xctrace", "export", "--input", trace_path, "--toc"])


def _export_toc(trace_path: str) -> ET.Element:
    return _parse_xml(_export_toc_text(trace_path))


def _table_refs_from_toc(toc: ET.Element) -> List[Dict[str, Any]]:
    data = toc.find("./run[@number='1']/data")
    if data is None:
        return []
    refs: List[Dict[str, Any]] = []
    for index, table in enumerate(data.findall('table'), start=1):
        refs.append(
            {
                'index': index,
                'schema': table.get('schema', ''),
                'attrs': dict(table.attrib),
            }
        )
    return refs


def _export_table_index(trace_path: str, table_index: int) -> Optional[ET.Element]:
    xpath = f'/trace-toc/run[@number="1"]/data/table[{table_index}]'
    root = _parse_xml(_run(["xctrace", "export", "--input", trace_path, "--xpath", xpath]))
    return root.find('node')


def _export_schema_node_legacy(trace_path: str, schema: str) -> Optional[ET.Element]:
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    root = _parse_xml(_run(["xctrace", "export", "--input", trace_path, "--xpath", xpath]))
    return root.find('node')


def _export_schema_nodes(trace_path: str, table_refs: Sequence[Dict[str, Any]], schema: str) -> List[Dict[str, Any]]:
    matches = [ref for ref in table_refs if ref.get('schema') == schema]
    exported: List[Dict[str, Any]] = []
    for ref in matches:
        node = _export_table_index(trace_path, int(ref['index']))
        if node is None:
            continue
        exported.append({'index': ref['index'], 'schema': schema, 'attrs': dict(ref.get('attrs', {})), 'node': node})

    if exported:
        return exported

    legacy = _export_schema_node_legacy(trace_path, schema)
    if legacy is None:
        return []
    return [{'index': 0, 'schema': schema, 'attrs': {}, 'node': legacy}]


def _id_index(node: ET.Element) -> Dict[str, ET.Element]:
    idx: Dict[str, ET.Element] = {}
    for elem in node.iter():
        elem_id = elem.get('id')
        if elem_id:
            idx[elem_id] = elem
    return idx


def _resolve_elem(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> Optional[ET.Element]:
    if elem is None:
        return None
    ref = elem.get('ref')
    if ref:
        return idx.get(ref)
    return elem


def _fmt(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> str:
    elem = _resolve_elem(elem, idx)
    if elem is None:
        return ''
    fmt = elem.get('fmt', '')
    if fmt:
        return fmt
    return (elem.text or '').strip()


def _ival(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> int:
    elem = _resolve_elem(elem, idx)
    if elem is None:
        return 0
    for candidate in ((elem.text or '').strip(), elem.get('fmt', '').strip()):
        if not candidate:
            continue
        cleaned = candidate.replace(',', '')
        m = re.search(r'-?[0-9]+', cleaned)
        if m:
            try:
                return int(m.group(0))
            except ValueError:
                pass
    return 0


def _fval(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> float:
    elem = _resolve_elem(elem, idx)
    if elem is None:
        return 0.0
    for candidate in ((elem.text or '').strip(), elem.get('fmt', '').strip()):
        if not candidate:
            continue
        cleaned = candidate.replace(',', '').replace('%', '')
        m = re.search(r'-?[0-9]+(?:\.[0-9]+)?', cleaned)
        if m:
            try:
                return float(m.group(0))
            except ValueError:
                pass
    return 0.0


def _u64_array(elem: Optional[ET.Element], idx: Dict[str, ET.Element]) -> List[int]:
    elem = _resolve_elem(elem, idx)
    if elem is None:
        return []

    values: List[int] = []
    for child in list(elem):
        resolved = _resolve_elem(child, idx)
        if resolved is None:
            continue
        if list(resolved):
            values.extend(_u64_array(resolved, idx))
            continue
        v = _ival(resolved, idx)
        if v != 0 or (resolved.text or '').strip() in ('0', '0.0'):
            values.append(v)

    if values:
        return values

    text = _fmt(elem, idx)
    if text:
        for token in re.split(r'[\s,;]+', text):
            token = token.strip()
            if not token:
                continue
            token = token.replace(',', '')
            try:
                values.append(int(token, 0))
            except ValueError:
                pass
    return values


def _find_child(row: ET.Element, tag: str) -> Optional[ET.Element]:
    for child in row:
        if child.tag == tag:
            return child
    return None


def _find_all_children(row: ET.Element, tag: str) -> List[ET.Element]:
    return [child for child in row if child.tag == tag]


def _iter_rows(tables: Sequence[Dict[str, Any]]) -> Iterable[Tuple[ET.Element, Dict[str, ET.Element], Dict[str, str]]]:
    for table in tables:
        node = table.get('node')
        if node is None:
            continue
        idx = _id_index(node)
        attrs = dict(table.get('attrs', {}))
        for row in node.findall('row'):
            yield row, idx, attrs


# ---------------------------------------------------------------------------
# Formatting / filtering helpers
# ---------------------------------------------------------------------------


def parse_duration_ns(text: str) -> int:
    text = text.strip().lower()
    match = re.match(r'^([0-9]*\.?[0-9]+)\s*(ns|us|ms|s)?$', text)
    if not match:
        raise ValueError(f'cannot parse duration: {text!r}')
    value = float(match.group(1))
    unit = match.group(2) or 's'
    scale = {'ns': 1, 'us': 1_000, 'ms': 1_000_000, 's': 1_000_000_000}[unit]
    return int(value * scale)


def parse_time_range(text: str) -> Tuple[int, int]:
    start_text, end_text = (part.strip() for part in text.split('-', 1))
    start_ns = parse_duration_ns(start_text) if start_text else 0
    end_ns = parse_duration_ns(end_text) if end_text else -1
    return start_ns, end_ns


def _ns_fmt(ns: int) -> str:
    if ns >= 1_000_000_000:
        return f'{ns / 1_000_000_000:.2f}s'
    if ns >= 1_000_000:
        return f'{ns / 1_000_000:.2f}ms'
    if ns >= 1_000:
        return f'{ns / 1_000:.2f}µs'
    return f'{ns}ns'


def _svg_escape(text: str) -> str:
    return (
        text.replace('&', '&amp;')
        .replace('<', '&lt;')
        .replace('>', '&gt;')
        .replace('"', '&quot;')
    )


def _matches_target(process_fmt: str, target_name: str, target_pid: str, process_filter: str) -> bool:
    lower = process_fmt.lower()
    if process_filter:
        return process_filter.lower() in lower
    if target_pid and target_pid in process_fmt:
        return True
    if target_name and target_name.lower() in lower:
        return True
    return False


def _target_from_toc(toc: ET.Element) -> Tuple[str, str]:
    proc = toc.find('.//process[@type="launched"]')
    if proc is not None:
        return proc.get('name', ''), proc.get('pid', '')
    proc2 = toc.find('.//target/process')
    if proc2 is not None:
        return proc2.get('name', ''), proc2.get('pid', '')
    return '', ''


def _shader_timeline_setting(toc_text: str) -> Optional[bool]:
    if 'Shader Timeline: Enabled' in toc_text:
        return True
    if 'Shader Timeline: Disabled' in toc_text:
        return False
    return None


def _base_shader_name(text: str) -> str:
    return re.sub(r'\s+\([0-9]+\)$', '', (text or '').strip()) or (text or '').strip()


# ---------------------------------------------------------------------------
# Signpost parsing (used to augment shader names / PSO labels)
# ---------------------------------------------------------------------------

FUNCTION_COMPILED_PATTERNS = [
    re.compile(
        r'Name=\s*(?P<name>.*?)\s+Label=\s*(?P<label>.*?)\s+Type=\s*(?P<type>.*?)\s+'
        r'ID=\s*(?P<id>\d+)\s+UniqueID=\s*(?P<uid>\d+)\s+RequestHash=\s*(?P<hash>.*?)\s+'
        r'Addr=\s*(?P<addr>[0-9,]+)\s+Size=\s*(?P<size>[0-9,]+)$'
    ),
    re.compile(
        r'Name=\s*(?P<name>.*?)\s+Label=\s*(?P<label>.*?)\s+Type=\s*(?P<type>.*?)\s+'
        r'ID=\s*(?P<id>\d+)\s+Addr=\s*(?P<addr>[0-9,]+)\s+Size=\s*(?P<size>[0-9,]+)$'
    ),
    re.compile(
        r'Name=\s*(?P<name>.*?)\s+Type=\s*(?P<type>.*?)\s+ID=\s*(?P<id>\d+)\s+'
        r'Addr=\s*(?P<addr>[0-9,]+)\s+Size=\s*(?P<size>[0-9,]+)$'
    ),
]

RENDER_PIPELINE_PATTERNS = [
    re.compile(
        r'Label=\s*(?P<label>.*?)\s+VertexID=\s*(?P<vertex>\d+)\s+FragmentID=\s*(?P<fragment>\d+)\s+TileID=\s*(?P<tile>\d+)$'
    ),
    re.compile(
        r'Label=\s*(?P<label>.*?)\s+VertexID=\s*(?P<vertex>\d+)\s+FragmentID=\s*(?P<fragment>\d+)\s+TileID=\s*(?P<tile>\d+)\s+MeshID=\s*(?P<mesh>\d+)\s+ObjectID=\s*(?P<object>\d+).*'
    ),
]

COMPUTE_PIPELINE_PATTERNS = [
    re.compile(r'Label=\s*(?P<label>.*?)\s+ID=\s*(?P<compute>\d+)$'),
    re.compile(r'Label=\s*(?P<label>.*?)\s+ID=\s*(?P<compute>\d+)\s+UniqueID=\s*(?P<uid>\d+)\s+RequestHash=.*'),
]


def _parse_int_group(match: re.Match[str], name: str) -> Optional[int]:
    value = match.groupdict().get(name)
    if not value:
        return None
    return int(value.replace(',', ''))


def _parse_signposts(signpost_tables: Sequence[Dict[str, Any]], target_name: str, target_pid: str, process_filter: str) -> Tuple[List[ShaderBinary], List[PSOInfo], int]:
    shaders: List[ShaderBinary] = []
    psos: List[PSOInfo] = []
    rows_seen = 0

    for row, idx, _attrs in _iter_rows(signpost_tables):
        process = _fmt(_find_child(row, 'process'), idx)
        if process and not _matches_target(process, target_name, target_pid, process_filter):
            continue
        rows_seen += 1
        signpost_name = _fmt(_find_child(row, 'signpost-name'), idx)
        metadata = _fmt(_find_child(row, 'os-log-metadata'), idx)
        time_ns = _ival(_find_child(row, 'event-time'), idx)

        if signpost_name == 'FunctionCompiled':
            for pattern in FUNCTION_COMPILED_PATTERNS:
                match = pattern.match(metadata)
                if not match:
                    continue
                name = match.group('name').strip()
                label = (match.groupdict().get('label') or '').strip()
                stage = match.group('type').strip().capitalize()
                shader_id = int((match.groupdict().get('uid') or match.group('id')).replace(',', ''))
                addr = int(match.group('addr').replace(',', ''))
                size = int(match.group('size').replace(',', ''))
                shaders.append(
                    ShaderBinary(
                        name=f"{name} ({shader_id})" if name else f"{stage} Shader ({shader_id})",
                        label=label,
                        stage=stage,
                        pso_name='',
                        shader_id=shader_id,
                        pc_start=addr,
                        pc_end=addr + size,
                        process=process,
                        timestamp_ns=time_ns,
                    )
                )
                break

        elif signpost_name == 'RenderPipelineLabel':
            for pattern in RENDER_PIPELINE_PATTERNS:
                match = pattern.match(metadata)
                if not match:
                    continue
                psos.append(
                    PSOInfo(
                        label=match.group('label').strip(),
                        process=process,
                        pso_type='Render',
                        vertex_id=_parse_int_group(match, 'vertex'),
                        fragment_id=_parse_int_group(match, 'fragment'),
                        tile_id=_parse_int_group(match, 'tile'),
                        mesh_id=_parse_int_group(match, 'mesh'),
                        object_id=_parse_int_group(match, 'object'),
                    )
                )
                break

        elif signpost_name == 'ComputePipelineLabel':
            for pattern in COMPUTE_PIPELINE_PATTERNS:
                match = pattern.match(metadata)
                if not match:
                    continue
                psos.append(
                    PSOInfo(
                        label=match.group('label').strip(),
                        process=process,
                        pso_type='Compute',
                        compute_id=_parse_int_group(match, 'compute'),
                    )
                )
                break

    return shaders, psos, rows_seen


# ---------------------------------------------------------------------------
# Trace parsing
# ---------------------------------------------------------------------------


def _collect_shader_binaries(
    shader_list_tables: Sequence[Dict[str, Any]],
    signpost_shaders: Sequence[ShaderBinary],
    pso_infos: Sequence[PSOInfo],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> List[ShaderBinary]:
    merged: Dict[Tuple[str, int, int], ShaderBinary] = {}

    def merge(shader: ShaderBinary) -> None:
        key = (shader.process or '', shader.shader_id, shader.pc_start)
        existing = merged.get(key)
        if existing is None:
            merged[key] = shader
            return
        merged[key] = ShaderBinary(
            name=shader.name or existing.name,
            label=shader.label or existing.label,
            stage=shader.stage or existing.stage,
            pso_name=shader.pso_name or existing.pso_name,
            shader_id=shader.shader_id or existing.shader_id,
            pc_start=shader.pc_start or existing.pc_start,
            pc_end=shader.pc_end or existing.pc_end,
            process=shader.process or existing.process,
            timestamp_ns=shader.timestamp_ns or existing.timestamp_ns,
        )

    for shader in signpost_shaders:
        merge(shader)

    for row, idx, _attrs in _iter_rows(shader_list_tables):
        process = _fmt(_find_child(row, 'process'), idx)
        if process and not _matches_target(process, target_name, target_pid, process_filter):
            continue

        labels = [_fmt(elem, idx) for elem in _find_all_children(row, 'metal-object-label') if _fmt(elem, idx)]
        uints = [_ival(elem, idx) for elem in _find_all_children(row, 'uint64')]
        stage = _fmt(_find_child(row, 'string'), idx).capitalize()
        shader_id = uints[0] if len(uints) > 0 else 0
        pc_start = uints[1] if len(uints) > 1 else 0
        pc_end = uints[2] if len(uints) > 2 else 0
        name = labels[0] if len(labels) > 0 else f'{stage} Shader ({shader_id})'
        label = labels[1] if len(labels) > 1 else ''
        if label and _base_shader_name(label) == _base_shader_name(name):
            label = ''
        pso_name = labels[2] if len(labels) > 2 else ''

        merge(
            ShaderBinary(
                name=name,
                label=label,
                stage=stage,
                pso_name=pso_name,
                shader_id=shader_id,
                pc_start=pc_start,
                pc_end=pc_end,
                process=process,
                timestamp_ns=_ival(_find_child(row, 'start-time'), idx),
            )
        )

    binaries = list(merged.values())

    if pso_infos:
        for idx, shader in enumerate(binaries):
            if shader.pso_name:
                continue
            for pso in pso_infos:
                if pso.process and shader.process and pso.process != shader.process:
                    continue
                ids = [pso.vertex_id, pso.fragment_id, pso.tile_id, pso.compute_id, pso.mesh_id, pso.object_id]
                if shader.shader_id in [value for value in ids if value is not None]:
                    binaries[idx] = ShaderBinary(
                        name=shader.name,
                        label=shader.label,
                        stage=shader.stage,
                        pso_name=pso.label,
                        shader_id=shader.shader_id,
                        pc_start=shader.pc_start,
                        pc_end=shader.pc_end,
                        process=shader.process,
                        timestamp_ns=shader.timestamp_ns,
                    )
                    break

    binaries.sort(key=lambda item: (item.process or '', item.pc_start, item.shader_id))
    return binaries


def _parse_shader_intervals(
    tables: Sequence[Dict[str, Any]],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> List[ShaderInterval]:
    intervals: List[ShaderInterval] = []
    for row, idx, _attrs in _iter_rows(tables):
        process = _fmt(_find_child(row, 'process'), idx)
        if process and not _matches_target(process, target_name, target_pid, process_filter):
            continue

        time_ns = _ival(_find_child(row, 'start-time'), idx)
        duration_ns = _ival(_find_child(row, 'duration'), idx)
        labels = [_fmt(elem, idx) for elem in _find_all_children(row, 'metal-object-label') if _fmt(elem, idx)]
        shader_name = _base_shader_name(labels[0]) if len(labels) > 0 else '<unknown-shader>'
        function_label = labels[1] if len(labels) > 1 else shader_name
        pso_name = labels[2] if len(labels) > 2 else ''
        shader_type = labels[3] if len(labels) > 3 else ''
        channel_name = _fmt(_find_child(row, 'gpu-channel-name'), idx)
        percents = [_fval(elem, idx) for elem in _find_all_children(row, 'percent')]
        percent_of_kick = percents[0] if len(percents) > 0 else 0.0
        total_kick_percent = percents[1] if len(percents) > 1 else 0.0

        intervals.append(
            ShaderInterval(
                time_ns=time_ns,
                duration_ns=duration_ns,
                shader_name=shader_name,
                function_label=function_label or shader_name,
                pso_name=pso_name,
                shader_type=(shader_type or channel_name or '').capitalize(),
                channel_name=channel_name,
                process=process,
                percent_of_kick=percent_of_kick,
                total_kick_percent=total_kick_percent,
            )
        )
    return intervals


def _pc_to_shader(pc: int, binaries: Sequence[ShaderBinary]) -> Optional[ShaderBinary]:
    for shader in binaries:
        if shader.pc_start <= pc < shader.pc_end:
            return shader
    return None


def _pc_frame_label(shader: ShaderBinary, pc: int) -> str:
    offset = max(0, pc - shader.pc_start)
    base = shader.label or shader.base_name
    if offset == 0:
        return base
    return f'{base}+0x{offset:x}'


def _parse_pc_intervals(binaries: Sequence[ShaderBinary], tables: Sequence[Dict[str, Any]]) -> List[ShaderPCInterval]:
    intervals: List[ShaderPCInterval] = []
    for row, idx, _attrs in _iter_rows(tables):
        time_ns = _ival(_find_child(row, 'start-time'), idx)
        duration_ns = _ival(_find_child(row, 'duration'), idx)
        uints = [_ival(elem, idx) for elem in _find_all_children(row, 'uint64')]
        uint32s = [_ival(elem, idx) for elem in _find_all_children(row, 'uint32')]
        pc = uints[0] if uints else 0
        submission_id = uint32s[0] if len(uint32s) > 0 else 0
        datamaster = uint32s[1] if len(uint32s) > 1 else 0
        shader = _pc_to_shader(pc, binaries)
        if shader is None:
            continue
        intervals.append(
            ShaderPCInterval(
                time_ns=time_ns,
                duration_ns=duration_ns,
                pc=pc,
                submission_id=submission_id,
                datamaster=datamaster,
                shader=shader,
            )
        )
    return intervals


def _parse_samples(binaries: Sequence[ShaderBinary], tables: Sequence[Dict[str, Any]]) -> Tuple[List[ShaderSample], int]:
    samples: List[ShaderSample] = []
    row_count = 0

    for row, idx, _attrs in _iter_rows(tables):
        row_count += 1
        time_ns = _ival(_find_child(row, 'event-time'), idx)
        pcs: List[int] = []
        array_elem = _find_child(row, 'uint64-array')
        if array_elem is not None:
            pcs = _u64_array(array_elem, idx)
        if not pcs:
            uints = [_ival(elem, idx) for elem in _find_all_children(row, 'uint64')]
            pcs = uints
        if not pcs:
            continue

        mapped: List[Tuple[int, ShaderBinary]] = []
        for pc in pcs:
            shader = _pc_to_shader(pc, binaries)
            if shader is not None:
                mapped.append((pc, shader))

        if not mapped:
            continue

        parts: List[str] = []
        current_shader_key: Optional[Tuple[str, int]] = None
        stage = mapped[0][1].stage or 'Shader'
        parts.append(stage)
        for pc, shader in mapped:
            shader_key = (shader.base_name, shader.shader_id)
            if shader_key != current_shader_key:
                parts.append(shader.base_name)
                current_shader_key = shader_key
            pc_label = _pc_frame_label(shader, pc)
            if pc_label != parts[-1]:
                parts.append(pc_label)

        samples.append(
            ShaderSample(
                time_ns=time_ns,
                pcs=pcs,
                stack_parts=parts,
                leaf_label=parts[-1],
                shader_name=mapped[-1][1].base_name,
                shader_type=mapped[-1][1].stage or stage,
            )
        )

    return samples, row_count


def _parse_gpu_interval_fallbacks(
    tables: Sequence[Dict[str, Any]],
    target_name: str,
    target_pid: str,
    process_filter: str,
) -> List[GPUIntervalFallback]:
    rows: List[GPUIntervalFallback] = []
    for row, idx, _attrs in _iter_rows(tables):
        process = _fmt(_find_child(row, 'process'), idx)
        if process and not _matches_target(process, target_name, target_pid, process_filter):
            continue
        durations = [_ival(elem, idx) for elem in _find_all_children(row, 'duration')]
        duration_ns = durations[0] if durations else 0
        rows.append(
            GPUIntervalFallback(
                time_ns=_ival(_find_child(row, 'start-time'), idx),
                duration_ns=duration_ns,
                channel_name=_fmt(_find_child(row, 'gpu-channel-name'), idx) or 'Shader',
                label=_fmt(_find_child(row, 'formatted-label'), idx),
                process=process,
            )
        )
    return rows


def load_trace(trace_path: str, process_filter: str = '') -> ShaderTraceData:
    toc_text = _export_toc_text(trace_path)
    toc = _parse_xml(toc_text)
    table_refs = _table_refs_from_toc(toc)
    target_name, target_pid = _target_from_toc(toc)

    shader_list_tables = _export_schema_nodes(trace_path, table_refs, 'metal-shader-profiler-shader-list')
    shader_interval_tables = _export_schema_nodes(trace_path, table_refs, 'metal-shader-profiler-intervals')
    shader_pc_interval_tables = _export_schema_nodes(trace_path, table_refs, 'gpu-shader-profiler-interval')
    shader_sample_tables = _export_schema_nodes(trace_path, table_refs, 'gpu-shader-profiler-sample')
    gpu_interval_tables = _export_schema_nodes(trace_path, table_refs, 'metal-gpu-intervals')
    signpost_tables = _export_schema_nodes(trace_path, table_refs, 'os-signpost')
    # Keep only ShaderTimeline signposts
    signpost_tables = [table for table in signpost_tables if table.get('attrs', {}).get('category', '').replace('"', '') == 'ShaderTimeline']

    signpost_shaders, pso_infos, signpost_rows = _parse_signposts(signpost_tables, target_name, target_pid, process_filter)
    shader_binaries = _collect_shader_binaries(shader_list_tables, signpost_shaders, pso_infos, target_name, target_pid, process_filter)
    shader_intervals = _parse_shader_intervals(shader_interval_tables, target_name, target_pid, process_filter)
    pc_intervals = _parse_pc_intervals(shader_binaries, shader_pc_interval_tables)
    samples, sample_rows = _parse_samples(shader_binaries, shader_sample_tables)
    gpu_interval_fallbacks = _parse_gpu_interval_fallbacks(gpu_interval_tables, target_name, target_pid, process_filter)

    return ShaderTraceData(
        trace_path=os.path.abspath(trace_path),
        target_name=target_name,
        target_pid=target_pid,
        process_filter=process_filter,
        shader_timeline_setting=_shader_timeline_setting(toc_text),
        shader_binaries=shader_binaries,
        shader_intervals=shader_intervals,
        pc_intervals=pc_intervals,
        samples=samples,
        gpu_interval_fallbacks=gpu_interval_fallbacks,
        pso_infos=pso_infos,
        signpost_rows=signpost_rows,
        sample_rows=sample_rows,
        pc_interval_rows=sum(1 for _ in _iter_rows(shader_pc_interval_tables)),
        interval_rows=len(shader_intervals),
    )


# ---------------------------------------------------------------------------
# Higher-level derived views
# ---------------------------------------------------------------------------


def _filter_time_ns(value: int, time_range: str) -> bool:
    start_ns, end_ns = parse_time_range(time_range)
    return value >= start_ns and (end_ns < 0 or value <= end_ns)


def filter_trace_data(data: ShaderTraceData, args: argparse.Namespace) -> ShaderTraceData:
    shader_filter = (getattr(args, 'shader', '') or '').lower()
    stage_filter = (getattr(args, 'stage', '') or '').lower()
    time_range = getattr(args, 'time_range', '') or ''

    def shader_match(name: str, stage: str) -> bool:
        ok = True
        if shader_filter:
            ok = shader_filter in name.lower()
        if ok and stage_filter:
            ok = stage_filter in stage.lower()
        return ok

    binaries = [b for b in data.shader_binaries if shader_match(b.base_name, b.stage)]
    binary_keys = {(b.shader_id, b.pc_start, b.pc_end) for b in binaries}

    intervals = [i for i in data.shader_intervals if shader_match(i.shader_name, i.shader_type) and (not time_range or _filter_time_ns(i.time_ns, time_range))]
    pc_intervals = [
        i for i in data.pc_intervals
        if i.shader is not None
        and (i.shader.shader_id, i.shader.pc_start, i.shader.pc_end) in binary_keys
        and (not time_range or _filter_time_ns(i.time_ns, time_range))
    ]
    samples = [
        s for s in data.samples
        if shader_match(s.shader_name, s.shader_type)
        and (not time_range or _filter_time_ns(s.time_ns, time_range))
    ]
    gpu_interval_fallbacks = [
        row for row in data.gpu_interval_fallbacks
        if (not stage_filter or stage_filter in row.channel_name.lower())
        and (not time_range or _filter_time_ns(row.time_ns, time_range))
    ]
    psos = [p for p in data.pso_infos if not shader_filter or shader_filter in p.label.lower()]

    return ShaderTraceData(
        trace_path=data.trace_path,
        target_name=data.target_name,
        target_pid=data.target_pid,
        process_filter=data.process_filter,
        shader_timeline_setting=data.shader_timeline_setting,
        shader_binaries=binaries,
        shader_intervals=intervals,
        pc_intervals=pc_intervals,
        samples=samples,
        gpu_interval_fallbacks=gpu_interval_fallbacks,
        pso_infos=psos,
        signpost_rows=data.signpost_rows,
        sample_rows=data.sample_rows,
        pc_interval_rows=data.pc_interval_rows,
        interval_rows=data.interval_rows,
    )


def _fallback_shader_name_for_channel(channel_name: str, binaries: Sequence[ShaderBinary]) -> str:
    channel_lower = (channel_name or '').lower()
    matching = [shader for shader in binaries if channel_lower in (shader.stage or '').lower()]
    unique = sorted({shader.base_name for shader in matching})
    if len(unique) == 1:
        return unique[0]
    if unique:
        return f"{channel_name} ({', '.join(unique[:3])}{'…' if len(unique) > 3 else ''})"
    return f'{channel_name} Shader'


def build_hotspots(data: ShaderTraceData) -> Tuple[str, List[Dict[str, Any]]]:
    if data.shader_intervals:
        agg: Dict[Tuple[str, str, str, str], Dict[str, Any]] = {}
        for interval in data.shader_intervals:
            key = (interval.shader_type or interval.channel_name or 'Shader', interval.shader_name, interval.function_label, interval.pso_name)
            item = agg.setdefault(
                key,
                {
                    'shader_type': key[0],
                    'shader_name': key[1],
                    'function_label': key[2],
                    'pso_name': key[3],
                    'duration_ns': 0,
                    'rows': 0,
                    'gpu_work_pct_total': 0.0,
                    'total_gpu_work_pct_total': 0.0,
                },
            )
            item['duration_ns'] += interval.duration_ns
            item['rows'] += 1
            item['gpu_work_pct_total'] += interval.percent_of_kick
            item['total_gpu_work_pct_total'] += interval.total_kick_percent
        rows = list(agg.values())
        for row in rows:
            count = max(1, row['rows'])
            row['avg_gpu_work_pct'] = row['gpu_work_pct_total'] / count
            row['avg_total_gpu_work_pct'] = row['total_gpu_work_pct_total'] / count
        rows.sort(key=lambda item: item['duration_ns'], reverse=True)
        return 'intervals', rows

    if data.pc_intervals:
        agg: Dict[Tuple[str, str, str], Dict[str, Any]] = {}
        for interval in data.pc_intervals:
            shader = interval.shader
            assert shader is not None
            label = _pc_frame_label(shader, interval.pc)
            key = (shader.stage or 'Shader', shader.base_name, label)
            item = agg.setdefault(
                key,
                {
                    'shader_type': key[0],
                    'shader_name': key[1],
                    'function_label': key[2],
                    'pso_name': shader.pso_name,
                    'duration_ns': 0,
                    'rows': 0,
                },
            )
            item['duration_ns'] += interval.duration_ns
            item['rows'] += 1
        rows = list(agg.values())
        rows.sort(key=lambda item: item['duration_ns'], reverse=True)
        return 'pc-intervals', rows

    if data.samples:
        agg: Dict[Tuple[str, str, str], Dict[str, Any]] = {}
        for sample in data.samples:
            key = (sample.shader_type or 'Shader', sample.shader_name, sample.leaf_label)
            item = agg.setdefault(
                key,
                {
                    'shader_type': key[0],
                    'shader_name': key[1],
                    'function_label': key[2],
                    'pso_name': '',
                    'duration_ns': 0,
                    'rows': 0,
                },
            )
            item['duration_ns'] += 1
            item['rows'] += 1
        rows = list(agg.values())
        rows.sort(key=lambda item: item['rows'], reverse=True)
        return 'samples', rows

    if data.gpu_interval_fallbacks:
        agg: Dict[Tuple[str, str], Dict[str, Any]] = {}
        for interval in data.gpu_interval_fallbacks:
            shader_name = _fallback_shader_name_for_channel(interval.channel_name, data.shader_binaries)
            key = (interval.channel_name or 'Shader', shader_name)
            item = agg.setdefault(
                key,
                {
                    'shader_type': key[0],
                    'shader_name': key[1],
                    'function_label': interval.label or shader_name,
                    'pso_name': '',
                    'duration_ns': 0,
                    'rows': 0,
                },
            )
            item['duration_ns'] += interval.duration_ns
            item['rows'] += 1
        rows = list(agg.values())
        rows.sort(key=lambda item: item['duration_ns'], reverse=True)
        return 'gpu-interval-fallback', rows

    return 'none', []


def build_weighted_stacks(data: ShaderTraceData) -> Tuple[str, Counter[str], str]:
    stacks: Counter[str] = Counter()

    if data.samples:
        for sample in data.samples:
            if not sample.stack_parts:
                continue
            stacks[';'.join(sample.stack_parts)] += 1
        return 'samples', stacks, 'samples'

    if data.shader_intervals:
        for interval in data.shader_intervals:
            parts = [interval.shader_type or interval.channel_name or 'Shader', interval.shader_name]
            label = interval.function_label or interval.shader_name
            if label and label != interval.shader_name:
                parts.append(label)
            weight = max(1, interval.duration_ns // 1_000)  # microseconds
            stacks[';'.join(parts)] += int(weight)
        return 'intervals', stacks, 'µs'

    if data.pc_intervals:
        for interval in data.pc_intervals:
            shader = interval.shader
            assert shader is not None
            parts = [shader.stage or 'Shader', shader.base_name, _pc_frame_label(shader, interval.pc)]
            weight = max(1, interval.duration_ns // 1_000)
            stacks[';'.join(parts)] += int(weight)
        return 'pc-intervals', stacks, 'µs'

    if data.gpu_interval_fallbacks:
        for interval in data.gpu_interval_fallbacks:
            shader_name = _fallback_shader_name_for_channel(interval.channel_name, data.shader_binaries)
            parts = [interval.channel_name or 'Shader', shader_name]
            weight = max(1, interval.duration_ns // 1_000)
            stacks[';'.join(parts)] += int(weight)
        return 'gpu-interval-fallback', stacks, 'µs'

    return 'none', stacks, ''


def build_callsite_tree(stacks: Counter[str]) -> FlameNode:
    root = FlameNode('all')
    root.total = sum(stacks.values())
    for stack, weight in stacks.items():
        if not stack:
            continue
        parts = stack.split(';')
        node = root
        for index, part in enumerate(parts):
            child = node.children.get(part)
            if child is None:
                child = FlameNode(part)
                node.children[part] = child
            child.total += weight
            if index == len(parts) - 1:
                child.self_value += weight
            node = child
    return root


# ---------------------------------------------------------------------------
# Human output
# ---------------------------------------------------------------------------


def print_info(data: ShaderTraceData, as_json: bool) -> int:
    payload = {
        'trace': data.trace_path,
        'target_name': data.target_name,
        'target_pid': data.target_pid,
        'process_filter': data.process_filter,
        'shader_timeline_setting': data.shader_timeline_setting,
        'compiled_shaders': len(data.shader_binaries),
        'pso_infos': len(data.pso_infos),
        'shader_interval_rows': len(data.shader_intervals),
        'pc_interval_rows': len(data.pc_intervals),
        'sample_rows': len(data.samples),
        'gpu_interval_fallback_rows': len(data.gpu_interval_fallbacks),
        'raw_sample_rows': data.sample_rows,
        'raw_pc_interval_rows': data.pc_interval_rows,
        'signpost_rows': data.signpost_rows,
        'shader_names': [shader.base_name for shader in data.shader_binaries],
    }

    if as_json:
        print(json.dumps(payload, indent=2))
        return 0

    print('Shader Trace Info')
    print('=================')
    print(f'Trace: {data.trace_path}')
    print(f'Target: {data.target_name or "<unknown>"} (pid {data.target_pid or "?"})')
    setting = data.shader_timeline_setting
    print(f'Shader Timeline setting: {"Enabled" if setting is True else "Disabled" if setting is False else "Unknown"}')
    print(f'Compiled shaders: {len(data.shader_binaries)}')
    print(f'PSO entries:      {len(data.pso_infos)}')
    print(f'Shader intervals: {len(data.shader_intervals)}')
    print(f'PC intervals:     {len(data.pc_intervals)} (raw rows: {data.pc_interval_rows})')
    print(f'Shader samples:   {len(data.samples)} (raw rows: {data.sample_rows})')
    print(f'GPU fallback rows:{len(data.gpu_interval_fallbacks)}')
    print(f'Shader signposts: {data.signpost_rows}')
    if data.shader_binaries:
        print('Shaders:')
        for shader in data.shader_binaries[:16]:
            pso = f' | PSO={shader.pso_name}' if shader.pso_name else ''
            label = f' | label={shader.label}' if shader.label else ''
            print(f'  - {shader.stage or "Shader"}: {shader.base_name} [{shader.pc_start:#x}-{shader.pc_end:#x}){label}{pso}')
    if not any([data.shader_intervals, data.pc_intervals, data.samples]):
        print('')
        print('No high-fidelity shader-profiler runtime rows are present in this trace yet.')
        print('If the trace was recorded with Shader Timeline enabled, the device / counter profile may still have declined to export samples.')
        if data.gpu_interval_fallbacks:
            print('A coarse stage/shader fallback is still available from metal-gpu-intervals.')
            return 0
        return 1
    return 0


def print_hotspots(data: ShaderTraceData, top: int, as_json: bool) -> int:
    mode, rows = build_hotspots(data)
    if not rows:
        print('No shader hotspot rows are available for this trace.', file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps({'mode': mode, 'rows': rows[:top]}, indent=2))
        return 0

    print('Shader Hotspots')
    print('===============')
    print(f'Trace: {data.trace_path}')
    print(f'Target: {data.target_name or "<unknown>"} (pid {data.target_pid or "?"})')
    print(f'Mode: {mode}')
    print('')

    if mode == 'samples':
        print(f"{'Samples':>8}  {'Self%':>6}  {'Stage':<10}  {'Shader':<28}  Callsite")
        print('─' * 90)
        total = sum(int(row['rows']) for row in rows[:top]) or 1
        for row in rows[:top]:
            pct = row['rows'] / total * 100.0
            print(f"{row['rows']:8d}  {pct:6.1f}%  {row['shader_type']:<10.10}  {_truncate(row['shader_name'], 28):<28}  {row['function_label']}")
    else:
        print(f"{'Duration':>10}  {'Rows':>6}  {'Stage':<10}  {'Shader':<28}  Callsite / Label")
        print('─' * 105)
        for row in rows[:top]:
            print(
                f"{_ns_fmt(int(row['duration_ns'])):>10}  {int(row['rows']):6d}  "
                f"{row['shader_type']:<10.10}  {_truncate(row['shader_name'], 28):<28}  {row['function_label']}"
            )
    return 0


def _truncate(text: str, max_len: int) -> str:
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + '…'


def _print_tree(node: FlameNode, total: int, depth: int, max_depth: int, min_pct: float, prefix: str = '') -> None:
    children = sorted(node.children.values(), key=lambda item: item.total, reverse=True)
    for index, child in enumerate(children):
        pct = (child.total / total * 100.0) if total else 0.0
        if pct < min_pct:
            continue
        branch = '└── ' if index == len(children) - 1 else '├── '
        print(f"{prefix}{branch}{pct:5.1f}%  {_truncate(child.name, 90)}")
        if depth + 1 < max_depth:
            next_prefix = prefix + ('    ' if index == len(children) - 1 else '│   ')
            _print_tree(child, total, depth + 1, max_depth, min_pct, next_prefix)


def print_callsites(data: ShaderTraceData, max_depth: int, min_pct: float) -> int:
    mode, stacks, units = build_weighted_stacks(data)
    if not stacks:
        print('No shader callsite stacks are available for this trace.', file=sys.stderr)
        return 1

    root = build_callsite_tree(stacks)
    print('Shader Callsites')
    print('================')
    print(f'Trace: {data.trace_path}')
    print(f'Target: {data.target_name or "<unknown>"} (pid {data.target_pid or "?"})')
    print(f'Mode: {mode} ({units})')
    print(f'Total weight: {root.total}')
    print('')
    _print_tree(root, root.total or 1, 0, max_depth, min_pct)
    return 0


def print_collapsed(data: ShaderTraceData) -> int:
    _mode, stacks, _units = build_weighted_stacks(data)
    if not stacks:
        print('No shader stacks are available for this trace.', file=sys.stderr)
        return 1
    for stack, weight in stacks.most_common():
        print(f'{stack} {weight}')
    return 0


# ---------------------------------------------------------------------------
# Flamegraph SVG generation
# ---------------------------------------------------------------------------


def write_flamegraph(data: ShaderTraceData, output: str, title: str, width: int, color_by: str) -> int:
    mode, stacks, units = build_weighted_stacks(data)
    if not stacks:
        print('No shader stacks are available for this trace.', file=sys.stderr)
        return 1

    total = sum(stacks.values())
    root = build_callsite_tree(stacks)

    def max_depth(node: FlameNode, depth: int = 0) -> int:
        if not node.children:
            return depth
        return max(max_depth(child, depth + 1) for child in node.children.values())

    depth = max_depth(root) + 1
    row_height = 18
    top_margin = 50
    bottom_margin = 10
    img_height = top_margin + depth * row_height + bottom_margin

    rects: List[Tuple[str, float, float, int, int, int]] = []

    def layout(node: FlameNode, x_frac: float, depth_index: int) -> None:
        if total <= 0:
            return
        width_frac = node.total / total
        if width_frac < 0.000001:
            return
        rects.append((node.name, x_frac, width_frac, depth_index, node.self_value, node.total))
        child_x = x_frac
        for child in sorted(node.children.values(), key=lambda item: item.total, reverse=True):
            layout(child, child_x, depth_index + 1)
            child_x += child.total / total

    layout(root, 0.0, 0)

    def heat_color(percent: float) -> str:
        r = 255
        g = int(210 * (1 - min(percent, 100.0) / 100.0))
        b = int(70 * (1 - min(percent, 100.0) / 100.0))
        return f'rgb({r},{g},{b})'

    def stage_color(name: str) -> str:
        base = name.split(';', 1)[0]
        stage = base.lower()
        if 'fragment' in stage:
            return 'rgb(255,125,90)'
        if 'vertex' in stage:
            return 'rgb(120,180,255)'
        if 'compute' in stage:
            return 'rgb(170,120,255)'
        if 'tile' in stage:
            return 'rgb(255,210,90)'
        return 'rgb(255,180,90)'

    svg: List[str] = []
    svg.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{img_height}" '
        f'viewBox="0 0 {width} {img_height}" font-family="monospace" font-size="11">'
    )
    svg.append('''<style>
  .frame rect { stroke-width: 0; }
  .frame rect:hover { stroke: #000; stroke-width: 0.5; cursor: pointer; }
  .frame text { pointer-events: none; fill: #000; dominant-baseline: central; }
  .title { font-size: 16px; font-weight: bold; fill: #333; }
  .subtitle { font-size: 11px; fill: #666; }
  .background { fill: #f8f8f8; }
</style>''')
    svg.append(f'<rect class="background" x="0" y="0" width="{width}" height="{img_height}"/>')
    svg.append(f'<text class="title" x="10" y="20">{_svg_escape(title)}</text>')
    svg.append(f'<text class="subtitle" x="10" y="36">shader mode: {mode} | total {total} {units}</text>')

    for name, x_frac, width_frac, depth_index, self_value, node_total in rects:
        x = x_frac * width
        w = width_frac * width
        if w < 0.5:
            continue
        y = img_height - bottom_margin - (depth_index + 1) * row_height
        pct = node_total / total * 100.0 if total else 0.0
        fill = stage_color(name) if color_by == 'stage' else heat_color(pct)
        tooltip = f'{name}\n{node_total} {units} ({pct:.1f}%)'
        if self_value:
            tooltip += f'\nself: {self_value} {units}'
        svg.append(f'<g class="frame"><title>{_svg_escape(tooltip)}</title>')
        svg.append(f'<rect x="{x:.3f}" y="{y}" width="{w:.3f}" height="{row_height - 1}" fill="{fill}"/>')
        if w >= 20:
            text_x = x + 3
            text_y = y + (row_height - 1) / 2
            label = _truncate(name, max(1, int(w / 7)))
            svg.append(f'<text x="{text_x:.3f}" y="{text_y:.3f}">{_svg_escape(label)}</text>')
        svg.append('</g>')

    svg.append('</svg>')

    with open(output, 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(svg))

    size = os.path.getsize(output)
    print(f'Flamegraph written to {output} ({size} bytes)', file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def add_common_filters(parser: argparse.ArgumentParser) -> None:
    parser.add_argument('--process', default='', help='Optional process substring override (default: launched target)')
    parser.add_argument('--stage', default='', help='Filter to shader stage substring (e.g. fragment, vertex, compute)')
    parser.add_argument('--shader', default='', help='Filter to shader name substring')
    parser.add_argument('--time-range', default='', help="Optional time window, e.g. '2.5s-3.0s' or '1s-'")


def main() -> int:
    ap = argparse.ArgumentParser(description='Analyze Metal shader-profiler traces from Instruments')
    sub = ap.add_subparsers(dest='command', required=True)

    p_info = sub.add_parser('info', help='Show shader-profiler availability and metadata')
    p_info.add_argument('trace', help='Path to .trace bundle')
    p_info.add_argument('--json', action='store_true', help='Emit machine-readable JSON')
    add_common_filters(p_info)

    p_hot = sub.add_parser('hotspots', help='Aggregate hottest shaders / callsites / PCs')
    p_hot.add_argument('trace', help='Path to .trace bundle')
    p_hot.add_argument('--top', type=int, default=20, help='Rows to show (default: 20)')
    p_hot.add_argument('--json', action='store_true', help='Emit machine-readable JSON')
    add_common_filters(p_hot)

    p_calls = sub.add_parser('callsites', help='Print a tree of shader callsites / PCs')
    p_calls.add_argument('trace', help='Path to .trace bundle')
    p_calls.add_argument('--depth', type=int, default=10, help='Max tree depth (default: 10)')
    p_calls.add_argument('--min-pct', type=float, default=1.0, help='Hide nodes below this percentage (default: 1.0)')
    add_common_filters(p_calls)

    p_collapsed = sub.add_parser('collapsed', help='Emit collapsed stacks for flamegraph tools')
    p_collapsed.add_argument('trace', help='Path to .trace bundle')
    add_common_filters(p_collapsed)

    p_flame = sub.add_parser('flamegraph', help='Generate interactive SVG shader flamegraph')
    p_flame.add_argument('trace', help='Path to .trace bundle')
    p_flame.add_argument('-o', '--output', default='shader-flamegraph.svg', help='Output SVG path')
    p_flame.add_argument('-t', '--title', default='', help='Chart title (default: auto)')
    p_flame.add_argument('-w', '--width', type=int, default=1400, help='SVG width in pixels (default: 1400)')
    p_flame.add_argument('--color-by', choices=['heat', 'stage'], default='stage', help='Color scheme (default: stage)')
    add_common_filters(p_flame)

    args = ap.parse_args()
    data = load_trace(args.trace, process_filter=getattr(args, 'process', '') or '')
    data = filter_trace_data(data, args)

    if args.command == 'info':
        return print_info(data, args.json)
    if args.command == 'hotspots':
        return print_hotspots(data, args.top, args.json)
    if args.command == 'callsites':
        return print_callsites(data, args.depth, args.min_pct)
    if args.command == 'collapsed':
        return print_collapsed(data)
    if args.command == 'flamegraph':
        title = args.title or f'Shader Flamegraph — {Path(args.trace).stem}'
        return write_flamegraph(data, args.output, title, args.width, args.color_by)

    ap.error(f'Unknown command: {args.command}')
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
