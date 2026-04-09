#!/usr/bin/env python3
"""trace-memory.py — Comprehensive memory analysis for macOS processes.

Wraps macOS memory CLI tools (vmmap, heap, leaks) and parses their output
into structured, human-readable reports. No external Python dependencies.

Subcommands:
  summary    Quick memory overview (vmmap + heap combined)
  leaks      Detect memory leaks with backtraces
  growth     Track memory growth over time
  regions    Detailed VM region map
  heap       Allocation hotspots by class/type

Works in two modes:
  PID mode:    -p <PID>         analyzes a running process
  Launch mode: -- command args   launches a process, analyzes it, then terminates it
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import textwrap
import time
from collections import OrderedDict
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TIMEOUT_SECS = 120
LAUNCH_SETTLE_SECS = 0.5

# ---------------------------------------------------------------------------
# Size parsing and formatting helpers
# ---------------------------------------------------------------------------

def parse_size(s: str) -> int:
    """Parse a size string like '32K', '4.5M', '1.2G', '848' into bytes.

    Recognizes:
      - Trailing K/KB → kilobytes
      - Trailing M/MB → megabytes
      - Trailing G/GB → gigabytes
      - Plain number   → bytes
    """
    s = s.strip()
    if not s or s == '-' or s == '—':
        return 0
    m = re.match(r'^([0-9]*\.?[0-9]+)\s*(K|KB|M|MB|G|GB|B)?$', s, re.IGNORECASE)
    if not m:
        return 0
    val = float(m.group(1))
    unit = (m.group(2) or 'B').upper()
    if unit in ('K', 'KB'):
        return int(val * 1024)
    elif unit in ('M', 'MB'):
        return int(val * 1024 * 1024)
    elif unit in ('G', 'GB'):
        return int(val * 1024 * 1024 * 1024)
    else:
        return int(val)


def format_size(n: int, precision: int = 1) -> str:
    """Format byte count into human-readable string: '32.0 KB', '4.5 MB'."""
    if n < 0:
        return '-' + format_size(-n, precision)
    if n == 0:
        return '0 B'
    if n < 1024:
        return f'{n} B'
    elif n < 1024 * 1024:
        return f'{n / 1024:.{precision}f} KB'
    elif n < 1024 * 1024 * 1024:
        return f'{n / (1024 * 1024):.{precision}f} MB'
    else:
        return f'{n / (1024 * 1024 * 1024):.{precision}f} GB'


def format_size_delta(n: int) -> str:
    """Format a size delta with +/- prefix."""
    if n == 0:
        return '—'
    sign = '+' if n > 0 else ''
    return f'{sign}{format_size(n)}'


# ---------------------------------------------------------------------------
# Process management helpers
# ---------------------------------------------------------------------------

def _check_pid_exists(pid: int) -> bool:
    """Check if a process with the given PID exists."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, but we can't signal it


def _get_process_name(pid: int) -> str:
    """Get process name from PID using ps."""
    try:
        r = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='],
                           capture_output=True, text=True, timeout=5)
        name = r.stdout.strip()
        return os.path.basename(name) if name else f'PID {pid}'
    except Exception:
        return f'PID {pid}'


def _launch_process(cmd: List[str], env_extra: Optional[Dict[str, str]] = None) -> subprocess.Popen:
    """Launch a process in the background, return Popen handle."""
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
    except FileNotFoundError:
        print(f"Error: Command not found: {cmd[0]}", file=sys.stderr)
        sys.exit(1)
    except PermissionError:
        print(f"Error: Permission denied: {cmd[0]}", file=sys.stderr)
        sys.exit(1)
    # Let the process settle
    time.sleep(LAUNCH_SETTLE_SECS)
    if proc.poll() is not None:
        print(f"Error: Process exited immediately (exit code {proc.returncode})", file=sys.stderr)
        sys.exit(1)
    return proc


def _terminate_process(proc: subprocess.Popen) -> None:
    """Gracefully terminate a launched process."""
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
    except Exception:
        pass


def _resolve_target(args) -> Tuple[int, str, Optional[subprocess.Popen]]:
    """Resolve PID from args. Returns (pid, process_name, launched_proc_or_None).

    Handles both -p PID and -- command modes.
    The env_extra dict is passed when launching processes (e.g. MallocStackLogging).
    """
    env_extra = getattr(args, '_env_extra', None)
    if args.pid:
        pid = args.pid
        if not _check_pid_exists(pid):
            print(f"Error: No process found with PID {pid}", file=sys.stderr)
            sys.exit(1)
        name = _get_process_name(pid)
        return pid, name, None
    elif args.command:
        proc = _launch_process(args.command, env_extra=env_extra)
        pid = proc.pid
        name = os.path.basename(args.command[0])
        return pid, name, proc
    else:
        print("Error: Specify -p PID or -- command [args...]", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Command runners
# ---------------------------------------------------------------------------

def _get_sudo_prefix_if_needed(pid: int) -> list:
    """Check if a process is owned by another user and acquire sudo if needed.
    Returns ['sudo'] or [] depending on whether sudo is required.
    Uses SUDO_ASKPASS with a macOS dialog for non-interactive environments."""
    try:
        r = subprocess.run(['ps', '-o', 'user=', '-p', str(pid)],
                           capture_output=True, text=True, timeout=5)
        owner = r.stdout.strip()
        import getpass
        if owner and owner != getpass.getuser():
            # Need sudo — check if already primed
            check = subprocess.run(['sudo', '-n', 'true'], capture_output=True, timeout=5)
            if check.returncode == 0:
                return ['sudo']
            
            # Not primed — use SUDO_ASKPASS with macOS dialog helper
            script_dir = os.path.dirname(os.path.realpath(__file__))
            askpass_helper = os.path.join(script_dir, 'sudo-askpass-helper.sh')
            if os.path.exists(askpass_helper):
                print(f"Process {pid} is owned by '{owner}' — sudo required.", file=sys.stderr)
                print("Requesting via password dialog...", file=sys.stderr)
                env = os.environ.copy()
                env['SUDO_ASKPASS'] = askpass_helper
                acq = subprocess.run(
                    ['sudo', '-A', 'true'],
                    env=env, capture_output=True, timeout=30
                )
                if acq.returncode == 0:
                    print("Sudo acquired.", file=sys.stderr)
                    # Now sudo is primed for this user — subsequent sudo calls work
                    return ['sudo']
                else:
                    print("Warning: Could not acquire sudo.", file=sys.stderr)
                    return []
            else:
                print(f"Process {pid} is owned by '{owner}' — run with sudo.", file=sys.stderr)
                return []
    except Exception:
        pass
    return []

def run_vmmap_summary(pid: int) -> str:
    """Run vmmap --summary and return stdout."""
    sudo_prefix = _get_sudo_prefix_if_needed(pid)
    try:
        r = subprocess.run(
            [*sudo_prefix, 'vmmap', '--summary', str(pid)],
            capture_output=True, text=True, timeout=TIMEOUT_SECS,
        )
    except FileNotFoundError:
        print("Error: vmmap not found. Ensure Xcode command-line tools are installed.", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("Error: vmmap timed out.", file=sys.stderr)
        sys.exit(1)
    if r.returncode != 0:
        stderr = r.stderr.strip()
        if 'permission' in stderr.lower() or 'not permitted' in stderr.lower():
            print(f"Error: Permission denied. Try: sudo trace-memory.py ...", file=sys.stderr)
        elif 'no process' in stderr.lower() or 'no such process' in stderr.lower():
            print(f"Error: Process {pid} not found.", file=sys.stderr)
        else:
            print(f"Error: vmmap failed (exit {r.returncode}): {stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout


def run_heap(pid: int) -> str:
    """Run heap and return stdout."""
    sudo_prefix = _get_sudo_prefix_if_needed(pid)
    try:
        r = subprocess.run(
            [*sudo_prefix, 'heap', str(pid)],
            capture_output=True, text=True, timeout=TIMEOUT_SECS,
        )
    except FileNotFoundError:
        print("Error: heap not found. Ensure Xcode command-line tools are installed.", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("Error: heap timed out.", file=sys.stderr)
        sys.exit(1)
    if r.returncode != 0:
        stderr = r.stderr.strip()
        if 'permission' in stderr.lower() or 'not permitted' in stderr.lower():
            print(f"Error: Permission denied. Try: sudo trace-memory.py ...", file=sys.stderr)
        else:
            print(f"Error: heap failed (exit {r.returncode}): {stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout


def run_leaks(pid: int) -> str:
    """Run leaks and return stdout. Auto-acquires sudo for root-owned processes."""
    sudo_prefix = _get_sudo_prefix_if_needed(pid)
    try:
        r = subprocess.run(
            [*sudo_prefix, 'leaks', str(pid)],
            capture_output=True, text=True, timeout=TIMEOUT_SECS,
        )
    except FileNotFoundError:
        print("Error: leaks not found. Ensure Xcode command-line tools are installed.", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("Error: leaks timed out.", file=sys.stderr)
        sys.exit(1)
    # leaks returns 1 if leaks are found — that's expected, not an error
    # Only treat it as error if stderr has actual errors
    if r.returncode != 0 and r.returncode != 1:
        stderr = r.stderr.strip()
        if 'permission' in stderr.lower() or 'not permitted' in stderr.lower() or 'not valid' in stderr.lower() or 'privilege' in stderr.lower():
            print(f"Error: leaks failed (exit {r.returncode}): {stderr}", file=sys.stderr)
        else:
            print(f"Error: leaks failed (exit {r.returncode}): {stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_vmmap_overview(text: str) -> Dict[str, int]:
    """Extract key metrics from vmmap --summary header."""
    result = {}
    patterns = {
        'physical_footprint_bytes': r'Physical footprint:\s+(.+)',
        'physical_footprint_peak_bytes': r'Physical footprint \(peak\):\s+(.+)',
    }
    for key, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            result[key] = parse_size(m.group(1).strip())

    return result


def parse_vmmap_regions(text: str) -> List[Dict[str, Any]]:
    """Parse the VM region table from vmmap --summary output.

    Returns a list of region dicts with keys:
      name, virtual_bytes, resident_bytes, dirty_bytes, swapped_bytes,
      volatile_bytes, nonvol_bytes, empty_bytes, count
    """
    regions = []
    # Find the region table — starts after the column header with VIRTUAL RESIDENT etc.
    lines = text.split('\n')
    in_table = False
    header_seen = False

    for line in lines:
        # Detect the header line
        if 'VIRTUAL' in line and 'RESIDENT' in line and 'DIRTY' in line and 'REGION' in line:
            # Check this is the VM REGION table, not the MALLOC ZONE table
            if 'MALLOC ZONE' not in line and 'ALLOCATION' not in line:
                in_table = True
                header_seen = False
                continue

        if in_table:
            # Skip separator lines
            if line.startswith('===') or line.strip().startswith('==='):
                if header_seen:
                    # This is the closing separator, check if next is TOTAL
                    in_table = False
                header_seen = True
                continue

            stripped = line.strip()
            if not stripped:
                if header_seen:
                    in_table = False
                continue

            # Parse a region line. The region name is variable-width and can contain spaces.
            # The numeric columns start at the first number after the region name.
            # Strategy: split from the right to get numeric columns, rest is region name.
            # Region lines have 8 numeric-ish fields: VIRTUAL, RESIDENT, DIRTY, SWAPPED, VOLATILE, NONVOL, EMPTY, COUNT
            # followed by optional annotation.

            # First, try to match TOTAL line
            if stripped.startswith('TOTAL'):
                # We'll handle this separately
                continue

            # Parse: find the position where numeric values start.
            # Numbers look like: 32K, 4096K, 802.7M, 0K, etc.
            # Use regex to extract all size-like tokens from the line
            # The region name is everything before the first numeric column.

            # Match pattern: region_name  number  number  number  number  number  number  number  number [annotation]
            m = re.match(
                r'^(.+?)\s{2,}'           # region name (at least 2 spaces before numbers)
                r'(\S+)\s+'               # VIRTUAL
                r'(\S+)\s+'               # RESIDENT
                r'(\S+)\s+'               # DIRTY
                r'(\S+)\s+'               # SWAPPED
                r'(\S+)\s+'               # VOLATILE
                r'(\S+)\s+'               # NONVOL
                r'(\S+)\s+'               # EMPTY
                r'(\d+)',                  # COUNT
                stripped
            )
            if m:
                region = {
                    'name': m.group(1).strip(),
                    'virtual_bytes': parse_size(m.group(2)),
                    'resident_bytes': parse_size(m.group(3)),
                    'dirty_bytes': parse_size(m.group(4)),
                    'swapped_bytes': parse_size(m.group(5)),
                    'volatile_bytes': parse_size(m.group(6)),
                    'nonvol_bytes': parse_size(m.group(7)),
                    'empty_bytes': parse_size(m.group(8)),
                    'count': int(m.group(9)),
                }
                regions.append(region)

    return regions


def parse_vmmap_totals(text: str) -> Dict[str, int]:
    """Parse the TOTAL row from vmmap --summary."""
    result = {
        'virtual_bytes': 0,
        'resident_bytes': 0,
        'dirty_bytes': 0,
        'swapped_bytes': 0,
    }
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('TOTAL'):
            m = re.match(
                r'^TOTAL\s+'
                r'(\S+)\s+'   # VIRTUAL
                r'(\S+)\s+'   # RESIDENT
                r'(\S+)\s+'   # DIRTY
                r'(\S+)',     # SWAPPED
                stripped
            )
            if m:
                result['virtual_bytes'] = parse_size(m.group(1))
                result['resident_bytes'] = parse_size(m.group(2))
                result['dirty_bytes'] = parse_size(m.group(3))
                result['swapped_bytes'] = parse_size(m.group(4))
                break
    return result


def parse_vmmap_malloc_zones(text: str) -> List[Dict[str, Any]]:
    """Parse the MALLOC ZONE table from vmmap --summary."""
    zones = []
    lines = text.split('\n')
    in_table = False
    header_seen = False

    for line in lines:
        if 'MALLOC ZONE' in line and 'VIRTUAL' in line:
            in_table = True
            header_seen = False
            continue

        if in_table:
            if line.strip().startswith('==='):
                if header_seen:
                    in_table = False
                header_seen = True
                continue

            stripped = line.strip()
            if not stripped:
                if header_seen:
                    in_table = False
                continue

            # Parse: ZONE_NAME  VIRTUAL  RESIDENT  DIRTY  SWAPPED  ALLOC_COUNT  BYTES_ALLOC  FRAG_SIZE  %FRAG  REGION_COUNT
            m = re.match(
                r'^(.+?)\s{2,}'
                r'(\S+)\s+'     # VIRTUAL
                r'(\S+)\s+'     # RESIDENT
                r'(\S+)\s+'     # DIRTY
                r'(\S+)\s+'     # SWAPPED
                r'(\d+)\s+'     # ALLOCATION COUNT
                r'(\S+)\s+'     # BYTES ALLOCATED
                r'(\S+)\s+'     # FRAG SIZE
                r'(\d+)%\s+'    # % FRAG
                r'(\d+)',       # REGION COUNT
                stripped
            )
            if m:
                zone = {
                    'name': m.group(1).strip(),
                    'virtual_bytes': parse_size(m.group(2)),
                    'resident_bytes': parse_size(m.group(3)),
                    'dirty_bytes': parse_size(m.group(4)),
                    'swapped_bytes': parse_size(m.group(5)),
                    'allocation_count': int(m.group(6)),
                    'bytes_allocated': parse_size(m.group(7)),
                    'frag_bytes': parse_size(m.group(8)),
                    'frag_pct': int(m.group(9)),
                    'region_count': int(m.group(10)),
                }
                zones.append(zone)

    return zones


def parse_heap_entries(text: str) -> List[Dict[str, Any]]:
    """Parse heap output into allocation entries.

    Returns list of dicts with keys:
      class_name, count, bytes, avg_bytes, type, binary
    """
    entries = []
    lines = text.split('\n')
    in_table = False

    for line in lines:
        stripped = line.strip()

        # Detect header
        if stripped.startswith('COUNT') and 'BYTES' in stripped and 'CLASS_NAME' in stripped:
            in_table = False  # Next line is separator
            continue
        if stripped.startswith('=====') and in_table is False:
            in_table = True
            continue
        if not in_table:
            continue
        if not stripped:
            continue

        # Parse entry line: COUNT  BYTES  AVG  CLASS_NAME  [TYPE  BINARY]
        # Fields are whitespace-separated but CLASS_NAME can have spaces.
        m = re.match(
            r'^\s*(\d+)\s+'        # COUNT
            r'(\d+)\s+'            # BYTES
            r'([0-9.]+)\s+'        # AVG
            r'(.+)',               # rest: CLASS_NAME [TYPE BINARY]
            line
        )
        if m:
            count = int(m.group(1))
            total_bytes = int(m.group(2))
            avg_bytes = float(m.group(3))
            rest = m.group(4)

            # The rest has CLASS_NAME, then optionally TYPE and BINARY
            # TYPE is a short word like C, ObjC, CFType, etc.
            # BINARY is a library name.
            # They're at fixed-ish column positions in the heap output.
            # Strategy: split from the right based on the known TYPE values.

            class_name = rest.strip()
            type_val = ''
            binary = ''

            # Try to match TYPE and BINARY from the tail
            # The heap output format has TYPE and BINARY after CLASS_NAME with significant spacing
            parts = re.match(
                r'^(.*?)\s{2,}(\S+)\s{2,}(\S+)\s*$',
                rest
            )
            if parts:
                class_name = parts.group(1).strip()
                type_val = parts.group(2).strip()
                binary = parts.group(3).strip()
            else:
                # Try just TYPE without BINARY
                parts2 = re.match(
                    r'^(.*?)\s{2,}(\S+)\s*$',
                    rest
                )
                if parts2:
                    candidate_type = parts2.group(2).strip()
                    # Only accept if it looks like a type token (C, ObjC, CFType, etc.)
                    if candidate_type in ('C', 'ObjC', 'CFType', 'C++', 'Swift'):
                        class_name = parts2.group(1).strip()
                        type_val = candidate_type
                    else:
                        # Might be a binary name or just part of class_name
                        class_name = rest.strip()

            entries.append({
                'class_name': class_name,
                'count': count,
                'bytes': total_bytes,
                'avg_bytes': avg_bytes,
                'type': type_val,
                'binary': binary,
            })

    return entries


def parse_heap_summary(text: str) -> Dict[str, Any]:
    """Parse the heap summary line: 'All zones: N nodes (B bytes)'."""
    result = {'total_nodes': 0, 'total_bytes': 0, 'zones': 0}
    m = re.search(r'Process \d+: (\d+) zone', text)
    if m:
        result['zones'] = int(m.group(1))

    m = re.search(r'All zones: (\d+) nodes \((\d+) bytes\)', text)
    if m:
        result['total_nodes'] = int(m.group(1))
        result['total_bytes'] = int(m.group(2))
    return result


def parse_leaks_output(text: str) -> Dict[str, Any]:
    """Parse leaks command output.

    Returns dict with:
      process_pid, total_nodes, total_bytes_malloced,
      leak_count, leak_bytes, leak_groups, is_clean
    """
    result = {
        'process_pid': 0,
        'total_nodes': 0,
        'total_bytes_malloced': '',
        'leak_count': 0,
        'leak_bytes': 0,
        'is_clean': True,
        'leak_groups': [],
    }

    # Parse: "Process 50376: 196 nodes malloced for 15 KB"
    m = re.search(r'Process (\d+): (\d+) nodes malloced for (.+)', text)
    if m:
        result['process_pid'] = int(m.group(1))
        result['total_nodes'] = int(m.group(2))
        result['total_bytes_malloced'] = m.group(3).strip()

    # Parse: "Process 50376: 10 leaks for 3200 total leaked bytes."
    m = re.search(r'Process \d+: (\d+) leaks? for (\d+) total leaked bytes', text)
    if m:
        result['leak_count'] = int(m.group(1))
        result['leak_bytes'] = int(m.group(2))
        result['is_clean'] = result['leak_count'] == 0

    # Parse STACK sections
    # "STACK OF N INSTANCES OF 'ROOT LEAK: <description>':"
    groups = []
    stack_pattern = re.compile(
        r"STACK OF (\d+) INSTANCES? OF '(.+?)':"
    )

    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        sm = stack_pattern.search(line)
        if sm:
            group = {
                'instances': int(sm.group(1)),
                'description': sm.group(2),
                'backtrace': [],
                'total_bytes': 0,
            }
            i += 1
            # Read backtrace lines until we hit an empty line or '===='
            while i < len(lines):
                bt_line = lines[i].strip()
                if not bt_line or bt_line.startswith('===='):
                    break
                # Backtrace line format:
                # 3   dyld                  0x18394bda4 start + 6992
                bt_m = re.match(
                    r'^(\d+)\s+'           # frame number
                    r'(\S+)\s+'            # binary
                    r'(0x[0-9a-fA-F]+)\s+' # address
                    r'(.+)',               # symbol + offset + optional source
                    bt_line
                )
                if bt_m:
                    group['backtrace'].append({
                        'frame': int(bt_m.group(1)),
                        'binary': bt_m.group(2),
                        'address': bt_m.group(3),
                        'symbol': bt_m.group(4).strip(),
                    })
                i += 1

            # Look for total bytes line after ====
            while i < len(lines):
                total_line = lines[i].strip()
                if not total_line:
                    i += 1
                    continue
                # "10 (3.12K) << TOTAL >>"
                tm = re.search(r'(\d+)\s+\(([^)]+)\)\s+<<\s*TOTAL\s*>>', total_line)
                if tm:
                    group['total_bytes'] = parse_size(tm.group(2))
                    i += 1
                    break
                # If we hit another STACK section or something else, stop
                if stack_pattern.search(total_line):
                    break
                i += 1

            groups.append(group)
        else:
            i += 1

    result['leak_groups'] = groups
    return result


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

def _table_line(width: int) -> str:
    """Create a horizontal rule using ─ character."""
    return '─' * width


def print_summary(pid: int, name: str, vmmap_text: str, heap_text: str,
                  top_n: int, as_json: bool) -> None:
    """Print combined summary from vmmap and heap."""
    overview = parse_vmmap_overview(vmmap_text)
    totals = parse_vmmap_totals(vmmap_text)
    regions = parse_vmmap_regions(vmmap_text)
    malloc_zones = parse_vmmap_malloc_zones(vmmap_text)
    heap_entries = parse_heap_entries(heap_text)
    heap_summary = parse_heap_summary(heap_text)

    if as_json:
        data = {
            'process': name,
            'pid': pid,
            **overview,
            **totals,
            'regions': regions[:top_n],
            'malloc_zones': malloc_zones,
            'heap_summary': heap_summary,
            'heap': heap_entries[:top_n],
        }
        print(json.dumps(data, indent=2))
        return

    phys = overview.get('physical_footprint_bytes', 0)
    phys_peak = overview.get('physical_footprint_peak_bytes', 0)
    virt = totals.get('virtual_bytes', 0)
    dirty = totals.get('dirty_bytes', 0)
    swapped = totals.get('swapped_bytes', 0)

    print(f"\nMemory Summary: {name} (PID {pid})\n")
    print("Overview:")
    print(f"  Physical footprint:   {format_size(phys):>10}")
    print(f"  Physical (peak):      {format_size(phys_peak):>10}")
    print(f"  Virtual:              {format_size(virt):>10}")
    print(f"  Dirty:                {format_size(dirty):>10}")
    print(f"  Swapped:              {format_size(swapped):>10}")

    if regions:
        # Sort by dirty size descending
        sorted_regions = sorted(regions, key=lambda r: r['dirty_bytes'], reverse=True)
        shown = sorted_regions[:top_n]

        print(f"\nTop VM Regions (by dirty size):")
        hdr = f"  {'Region':<30} {'Dirty':>10}  {'Virtual':>10}  {'Resident':>10}  {'Count':>6}"
        print(hdr)
        print(f"  {_table_line(len(hdr) - 2)}")
        for r in shown:
            print(f"  {r['name']:<30} {format_size(r['dirty_bytes']):>10}"
                  f"  {format_size(r['virtual_bytes']):>10}"
                  f"  {format_size(r['resident_bytes']):>10}"
                  f"  {r['count']:>6}")

    if malloc_zones:
        print(f"\nMalloc Zones:")
        hdr = f"  {'Zone':<40} {'Dirty':>10}  {'Allocated':>10}  {'Frag':>6}  {'Allocs':>8}"
        print(hdr)
        print(f"  {_table_line(len(hdr) - 2)}")
        for z in malloc_zones:
            zone_name = z['name']
            # Truncate long zone names
            if len(zone_name) > 38:
                zone_name = zone_name[:35] + '...'
            print(f"  {zone_name:<40} {format_size(z['dirty_bytes']):>10}"
                  f"  {format_size(z['bytes_allocated']):>10}"
                  f"  {z['frag_pct']:>4}%"
                  f"  {z['allocation_count']:>8}")

    if heap_entries:
        sorted_heap = sorted(heap_entries, key=lambda e: e['bytes'], reverse=True)
        shown = sorted_heap[:top_n]

        print(f"\nTop Heap Allocations (by size):")
        hdr = f"  {'Class':<40} {'Count':>8}  {'Total Size':>12}  {'Avg Size':>10}  {'Binary'}"
        print(hdr)
        print(f"  {_table_line(len(hdr) - 2)}")
        for e in shown:
            cls = e['class_name']
            if len(cls) > 38:
                cls = cls[:35] + '...'
            binary = e.get('binary', '')
            print(f"  {cls:<40} {e['count']:>8}"
                  f"  {format_size(e['bytes']):>12}"
                  f"  {format_size(int(e['avg_bytes'])):>10}"
                  f"  {binary}")

    print()


def print_leaks_report(pid: int, name: str, leaks_text: str, top_n: int,
                       as_json: bool) -> None:
    """Print formatted leaks report."""
    result = parse_leaks_output(leaks_text)

    if as_json:
        data = {
            'process': name,
            'pid': pid,
            **result,
        }
        print(json.dumps(data, indent=2))
        return

    print(f"\nLeak Report: {name} (PID {pid})\n")

    if result['is_clean']:
        print(f"Process {pid}: 0 leaks ✓\n")
        return

    print(f"Process {pid}: {result['leak_count']} leaks for "
          f"{format_size(result['leak_bytes'])} total leaked bytes.\n")

    for group in result['leak_groups'][:top_n]:
        total_str = format_size(group['total_bytes']) if group['total_bytes'] else '?'
        print(f"LEAK GROUP: {group['description']} "
              f"({group['instances']} instances, {total_str})")
        if group['backtrace']:
            print("  Backtrace:")
            for frame in group['backtrace']:
                print(f"    {frame['frame']:<4}{frame['binary']:<30} {frame['symbol']}")
        print()


def print_growth_report(pid: int, name: str, snapshots: List[Dict[str, Any]],
                        duration: float, interval: float, as_json: bool) -> None:
    """Print memory growth timeline."""
    if not snapshots:
        print("Error: No snapshots collected.", file=sys.stderr)
        return

    if as_json:
        data = {
            'process': name,
            'pid': pid,
            'duration_secs': duration,
            'interval_secs': interval,
            'snapshots': snapshots,
        }
        # Compute growth rate
        if len(snapshots) >= 2:
            first = snapshots[0].get('physical_footprint_bytes', 0)
            last = snapshots[-1].get('physical_footprint_bytes', 0)
            elapsed = snapshots[-1].get('time', duration)
            if elapsed > 0:
                data['growth_rate_bytes_per_sec'] = (last - first) / elapsed
        print(json.dumps(data, indent=2))
        return

    print(f"\nMemory Growth: {name} (PID {pid})")
    print(f"Duration: {duration:.1f}s | Interval: {interval:.1f}s\n")

    hdr = f"{'Time':>8}  {'Footprint':>12}  {'Dirty':>10}  {'Virtual':>10}  {'ΔFootprint':>12}"
    print(hdr)
    print(_table_line(len(hdr)))

    first_fp = snapshots[0].get('physical_footprint_bytes', 0) if snapshots else 0

    for snap in snapshots:
        t = snap.get('time', 0)
        fp = snap.get('physical_footprint_bytes', 0)
        dirty = snap.get('dirty_bytes', 0)
        virt = snap.get('virtual_bytes', 0)

        if t == 0:
            delta_str = '—'
        else:
            delta = fp - first_fp
            delta_str = format_size_delta(delta)

        print(f"{t:>7.1f}s  {format_size(fp):>12}  {format_size(dirty):>10}"
              f"  {format_size(virt):>10}  {delta_str:>12}")

    # Growth rate
    if len(snapshots) >= 2:
        first_fp = snapshots[0].get('physical_footprint_bytes', 0)
        last_fp = snapshots[-1].get('physical_footprint_bytes', 0)
        total_time = snapshots[-1].get('time', duration)
        if total_time > 0:
            rate = (last_fp - first_fp) / total_time
            print(f"\nGrowth Rate: {format_size(int(abs(rate)))}/s")

    # Show growing regions
    if len(snapshots) >= 2:
        first_regions = {r['name']: r for r in snapshots[0].get('regions', [])}
        last_regions = {r['name']: r for r in snapshots[-1].get('regions', [])}

        growing = []
        for name_r, last_r in last_regions.items():
            first_r = first_regions.get(name_r)
            if first_r:
                delta = last_r['dirty_bytes'] - first_r['dirty_bytes']
                if delta > 0:
                    growing.append((name_r, first_r['dirty_bytes'], last_r['dirty_bytes'], delta))

        if growing:
            growing.sort(key=lambda x: x[3], reverse=True)
            print("\nGrowing Regions:")
            for rname, first_d, last_d, delta in growing[:10]:
                print(f"  {rname}: {format_size(first_d)} → {format_size(last_d)} "
                      f"({format_size_delta(delta)})")

    print()


def print_regions_report(pid: int, name: str, vmmap_text: str, top_n: int,
                         as_json: bool) -> None:
    """Print detailed VM regions report."""
    regions = parse_vmmap_regions(vmmap_text)
    totals = parse_vmmap_totals(vmmap_text)
    overview = parse_vmmap_overview(vmmap_text)
    malloc_zones = parse_vmmap_malloc_zones(vmmap_text)

    if as_json:
        data = {
            'process': name,
            'pid': pid,
            **overview,
            **totals,
            'regions': regions,
            'malloc_zones': malloc_zones,
        }
        print(json.dumps(data, indent=2))
        return

    print(f"\nVM Regions: {name} (PID {pid})\n")

    phys = overview.get('physical_footprint_bytes', 0)
    print(f"Physical footprint: {format_size(phys)}\n")

    # Sort by virtual size descending by default
    sorted_regions = sorted(regions, key=lambda r: r['virtual_bytes'], reverse=True)
    shown = sorted_regions[:top_n]

    hdr = (f"  {'Region':<30} {'Virtual':>10}  {'Resident':>10}  {'Dirty':>10}"
           f"  {'Swapped':>10}  {'Count':>6}")
    print(hdr)
    print(f"  {_table_line(len(hdr) - 2)}")

    for r in shown:
        print(f"  {r['name']:<30} {format_size(r['virtual_bytes']):>10}"
              f"  {format_size(r['resident_bytes']):>10}"
              f"  {format_size(r['dirty_bytes']):>10}"
              f"  {format_size(r['swapped_bytes']):>10}"
              f"  {r['count']:>6}")

    # Print totals
    print(f"  {_table_line(len(hdr) - 2)}")
    print(f"  {'TOTAL':<30} {format_size(totals['virtual_bytes']):>10}"
          f"  {format_size(totals['resident_bytes']):>10}"
          f"  {format_size(totals['dirty_bytes']):>10}"
          f"  {format_size(totals['swapped_bytes']):>10}"
          f"  {len(regions):>6}")

    if malloc_zones:
        print(f"\nMalloc Zones:")
        zhdr = (f"  {'Zone':<40} {'Virtual':>10}  {'Resident':>10}  {'Dirty':>10}"
                f"  {'Allocated':>10}  {'Frag%':>6}  {'Allocs':>8}")
        print(zhdr)
        print(f"  {_table_line(len(zhdr) - 2)}")
        for z in malloc_zones:
            zname = z['name']
            if len(zname) > 38:
                zname = zname[:35] + '...'
            print(f"  {zname:<40} {format_size(z['virtual_bytes']):>10}"
                  f"  {format_size(z['resident_bytes']):>10}"
                  f"  {format_size(z['dirty_bytes']):>10}"
                  f"  {format_size(z['bytes_allocated']):>10}"
                  f"  {z['frag_pct']:>4}%"
                  f"  {z['allocation_count']:>8}")

    print()


def print_heap_report(pid: int, name: str, heap_text: str, top_n: int,
                      as_json: bool) -> None:
    """Print heap allocation report."""
    entries = parse_heap_entries(heap_text)
    summary = parse_heap_summary(heap_text)

    if as_json:
        data = {
            'process': name,
            'pid': pid,
            **summary,
            'allocations': entries[:top_n],
        }
        print(json.dumps(data, indent=2))
        return

    print(f"\nHeap Allocations: {name} (PID {pid})\n")
    print(f"Zones: {summary['zones']}  |  "
          f"Total nodes: {summary['total_nodes']}  |  "
          f"Total bytes: {format_size(summary['total_bytes'])}\n")

    if not entries:
        print("  No heap allocations found.\n")
        return

    # Sort by size
    by_size = sorted(entries, key=lambda e: e['bytes'], reverse=True)
    shown_size = by_size[:top_n]

    hdr = f"  {'Class':<40} {'Count':>8}  {'Total Size':>12}  {'Avg Size':>10}  {'Type':<8} {'Binary'}"
    print("By Total Size:")
    print(hdr)
    print(f"  {_table_line(len(hdr) - 2)}")
    for e in shown_size:
        cls = e['class_name']
        if len(cls) > 38:
            cls = cls[:35] + '...'
        print(f"  {cls:<40} {e['count']:>8}"
              f"  {format_size(e['bytes']):>12}"
              f"  {format_size(int(e['avg_bytes'])):>10}"
              f"  {e.get('type', ''):<8} {e.get('binary', '')}")

    # Also show by count if different ordering
    by_count = sorted(entries, key=lambda e: e['count'], reverse=True)
    if by_count[:top_n] != shown_size:
        print(f"\nBy Count:")
        print(hdr)
        print(f"  {_table_line(len(hdr) - 2)}")
        for e in by_count[:top_n]:
            cls = e['class_name']
            if len(cls) > 38:
                cls = cls[:35] + '...'
            print(f"  {cls:<40} {e['count']:>8}"
                  f"  {format_size(e['bytes']):>12}"
                  f"  {format_size(int(e['avg_bytes'])):>10}"
                  f"  {e.get('type', ''):<8} {e.get('binary', '')}")

    print()


# ---------------------------------------------------------------------------
# Subcommand implementations
# ---------------------------------------------------------------------------

def cmd_summary(args) -> None:
    """Execute the summary subcommand."""
    pid, name, proc = _resolve_target(args)
    try:
        print("Collecting memory data...", file=sys.stderr)
        vmmap_text = run_vmmap_summary(pid)
        heap_text = run_heap(pid)
        print_summary(pid, name, vmmap_text, heap_text,
                      top_n=args.top, as_json=args.json)
    finally:
        if proc:
            _terminate_process(proc)


def cmd_leaks(args) -> None:
    """Execute the leaks subcommand."""
    # For launch mode, set MallocStackLogging so leaks can show backtraces
    if args.command:
        args._env_extra = {'MallocStackLogging': '1'}
    pid, name, proc = _resolve_target(args)
    try:
        print("Running leak detection...", file=sys.stderr)
        leaks_text = run_leaks(pid)
        print_leaks_report(pid, name, leaks_text,
                           top_n=args.top, as_json=args.json)
    finally:
        if proc:
            _terminate_process(proc)


def cmd_growth(args) -> None:
    """Execute the growth subcommand."""
    pid, name, proc = _resolve_target(args)
    try:
        duration = args.duration
        interval = args.interval
        snapshots = []
        start_time = time.monotonic()

        num_snapshots = max(1, int(duration / interval)) + 1
        print(f"Tracking memory growth for {duration:.1f}s "
              f"(every {interval:.1f}s)...", file=sys.stderr)

        for i in range(num_snapshots):
            elapsed = time.monotonic() - start_time
            if elapsed > duration + 0.1 and i > 0:
                break

            # Check process is still alive
            if not _check_pid_exists(pid):
                print(f"Process {pid} exited during tracking.", file=sys.stderr)
                break

            print(f"  Snapshot {i + 1}/{num_snapshots}...", file=sys.stderr)
            try:
                vmmap_text = run_vmmap_summary(pid)
            except SystemExit:
                # vmmap failed — process may have exited
                print(f"  vmmap failed at snapshot {i + 1}, stopping.", file=sys.stderr)
                break

            overview = parse_vmmap_overview(vmmap_text)
            totals = parse_vmmap_totals(vmmap_text)
            regions = parse_vmmap_regions(vmmap_text)

            snap = {
                'time': round(elapsed, 1),
                **overview,
                **totals,
                'regions': regions,
            }
            snapshots.append(snap)

            # Wait for next interval (except on last iteration)
            if i < num_snapshots - 1:
                next_time = (i + 1) * interval
                wait = next_time - (time.monotonic() - start_time)
                if wait > 0:
                    time.sleep(wait)

        print_growth_report(pid, name, snapshots, duration, interval,
                            as_json=args.json)
    finally:
        if proc:
            _terminate_process(proc)


def cmd_regions(args) -> None:
    """Execute the regions subcommand."""
    pid, name, proc = _resolve_target(args)
    try:
        print("Collecting VM region data...", file=sys.stderr)
        vmmap_text = run_vmmap_summary(pid)
        print_regions_report(pid, name, vmmap_text,
                             top_n=args.top, as_json=args.json)
    finally:
        if proc:
            _terminate_process(proc)


def cmd_heap(args) -> None:
    """Execute the heap subcommand."""
    pid, name, proc = _resolve_target(args)
    try:
        print("Collecting heap data...", file=sys.stderr)
        heap_text = run_heap(pid)
        print_heap_report(pid, name, heap_text,
                          top_n=args.top, as_json=args.json)
    finally:
        if proc:
            _terminate_process(proc)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser."""
    parser = argparse.ArgumentParser(
        prog='trace-memory.py',
        description='Comprehensive memory analysis for macOS processes.\n\n'
                    'Wraps vmmap, heap, and leaks into structured reports.\n'
                    'Use -p PID to analyze a running process, or -- command to launch one.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent('''\
            Examples:
              trace-memory.py summary -p 12345
              trace-memory.py leaks -- ./my_app --flag
              trace-memory.py growth -d 30 --interval 5 -p 12345
              trace-memory.py summary --json -- /usr/bin/yes | jq .
        '''),
    )

    subparsers = parser.add_subparsers(dest='mode', help='Analysis mode')

    # Common arguments added to each subparser
    def add_common_args(p):
        target = p.add_mutually_exclusive_group()
        target.add_argument('-p', '--pid', type=int, help='Analyze running process by PID')
        p.add_argument('--json', action='store_true', help='Output as JSON')
        p.add_argument('--top', type=int, default=20,
                       help='Top entries to show (default: 20)')
        p.add_argument('command', nargs='*', default=None,
                       help='Command to launch (after --)')

    # -- summary -----------------------------------------------------------
    p_summary = subparsers.add_parser(
        'summary', help='Quick memory overview (vmmap + heap combined)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_common_args(p_summary)

    # -- leaks -------------------------------------------------------------
    p_leaks = subparsers.add_parser(
        'leaks', help='Detect memory leaks with backtraces',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_common_args(p_leaks)

    # -- growth ------------------------------------------------------------
    p_growth = subparsers.add_parser(
        'growth', help='Track memory growth over time',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_common_args(p_growth)
    p_growth.add_argument('-d', '--duration', type=float, default=10.0,
                          help='Duration in seconds (default: 10)')
    p_growth.add_argument('--interval', type=float, default=2.0,
                          help='Snapshot interval in seconds (default: 2)')

    # -- regions -----------------------------------------------------------
    p_regions = subparsers.add_parser(
        'regions', help='Detailed VM region map',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_common_args(p_regions)

    # -- heap --------------------------------------------------------------
    p_heap = subparsers.add_parser(
        'heap', help='Allocation hotspots by class/type',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_common_args(p_heap)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.mode:
        # Default to summary if no mode specified but args present
        # Re-parse with 'summary' prepended
        if len(sys.argv) > 1 and (sys.argv[1].startswith('-') or sys.argv[1] == '--'):
            sys.argv.insert(1, 'summary')
            args = parser.parse_args()
        else:
            parser.print_help()
            sys.exit(1)

    # Handle the command argument: argparse puts everything after -- into command
    # But we need to handle the case where command is empty list vs None
    if not args.command:
        args.command = None

    # Ensure we have a target
    if not args.pid and not args.command:
        print("Error: Specify -p PID or -- command [args...]", file=sys.stderr)
        sys.exit(1)

    # Initialize _env_extra attribute
    if not hasattr(args, '_env_extra'):
        args._env_extra = None

    commands = {
        'summary': cmd_summary,
        'leaks': cmd_leaks,
        'growth': cmd_growth,
        'regions': cmd_regions,
        'heap': cmd_heap,
    }

    try:
        commands[args.mode](args)
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        if os.environ.get('TRACE_MEMORY_DEBUG'):
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
