# Metal examples

This directory contains four standalone Swift + Metal demos:

- `metal_compute_demo.swift` — compiles an inline Metal compute shader, dispatches it repeatedly, and prints a checksum.
- `metal_render_demo.swift` — builds a render pipeline with vertex + fragment shaders and repeatedly renders to an offscreen texture.
- `metal_window_demo.swift` — creates a real `MTKView` window, presents drawables through `CAMetalLayer`, and is useful for tracing present/IOSurface/compositor behavior.
- `metal_pbr_shadow_demo.swift` — a fixed 3D MTKView scene with a PBR-shaded sphere over a plane, directional lighting, and a shadow-map pass. It is designed to generate richer, deterministic GPU traces with clearly labeled passes and resources.

All four demos now support **programmatic `.gputrace` capture** via `MTLCaptureManager`:
- `--capture PATH` captures the first representative dispatch / frame and continues running.
- `--capture-only PATH` captures the first representative dispatch / frame and exits immediately.
- Re-run with `MTL_CAPTURE_ENABLED=1` when you want the capture APIs to be available from a standalone binary.

Important mental model:
- **`xctrace` / Instruments CLI records `.trace`**, not `.gputrace`.
- **`.gputrace` comes from host-side capture code** (these examples already include it) or from the Xcode Metal Debugger GUI.

## Build

```bash
mkdir -p build/examples
swiftc -O -g examples/metal_compute_demo.swift -o build/examples/metal_compute_demo
swiftc -O -g examples/metal_render_demo.swift -o build/examples/metal_render_demo
swiftc -O -g examples/metal_window_demo.swift -o build/examples/metal_window_demo
swiftc -O -g examples/metal_pbr_shadow_demo.swift -o build/examples/metal_pbr_shadow_demo
```

## Run

```bash
build/examples/metal_compute_demo --seconds 2 --elements 262144 --iterations 64
build/examples/metal_render_demo --seconds 2 --width 1024 --height 1024 --iterations 32 --draws 32
build/examples/metal_window_demo --seconds 4 --width 960 --height 540 --draws 16 --fps 60
build/examples/metal_pbr_shadow_demo --seconds 4 --width 1280 --height 720 --fps 60 --shadow-map-size 2048
```

## Capture `.gputrace` bundles from the examples

```bash
# Compute demo: capture the first dispatch and exit
MTL_CAPTURE_ENABLED=1 \
  build/examples/metal_compute_demo \
  --capture-only build/examples/metal_compute_demo.gputrace \
  --seconds 0.2 --elements 8192 --iterations 8

# Offscreen render demo: capture the first frame and exit
MTL_CAPTURE_ENABLED=1 \
  build/examples/metal_render_demo \
  --capture-only build/examples/metal_render_demo.gputrace \
  --seconds 0.2 --width 256 --height 256 --iterations 4 --draws 4

# Windowed MTKView demo: capture the first presented frame and exit
MTL_CAPTURE_ENABLED=1 \
  build/examples/metal_window_demo \
  --capture-only build/examples/metal_window_demo.gputrace \
  --seconds 0.5 --width 640 --height 360 --draws 4 --fps 30

# Fixed PBR scene: capture the first presented frame and exit
MTL_CAPTURE_ENABLED=1 \
  build/examples/metal_pbr_shadow_demo \
  --capture-only build/examples/metal_pbr_shadow_demo.gputrace \
  --seconds 0.5 --width 800 --height 600 --fps 30 --shadow-map-size 1024
```

## Inspect `.gputrace` bundles from the CLI

```bash
# Human-readable overview
python3 scripts/trace-gputrace.py info build/examples/metal_compute_demo.gputrace

# Machine-readable JSON
python3 scripts/trace-gputrace.py info build/examples/metal_compute_demo.gputrace --json > compute_capture.json

# Resource inventory + shader names
python3 scripts/trace-gputrace.py resources build/examples/metal_render_demo.gputrace

# Decode a captured buffer by label with a flexible layout
python3 scripts/trace-gputrace.py buffer build/examples/metal_compute_demo.gputrace \
  --buffer "Compute Values Buffer" --layout float --index 0-8

python3 scripts/trace-gputrace.py buffer build/examples/metal_window_demo.gputrace \
  --buffer "Window Vertices" --layout "float2,float4" --index 0-2

# Dump extracted printable strings from the bundle internals
python3 scripts/trace-gputrace.py strings build/examples/metal_render_demo.gputrace --limit 80

# Generate an HTML report for browser inspection
python3 scripts/trace-gputrace.py report build/examples/metal_window_demo.gputrace \
  -o build/examples/metal_window_capture_report.html
```

## Trace with xtrace

```bash
# Compute demo, Metal System Trace
scripts/xtrace --gpu -d 8 build/examples/metal_compute_demo --seconds 6

# Offscreen render demo, Metal System Trace
scripts/xtrace --gpu -d 8 build/examples/metal_render_demo --seconds 4 --width 1024 --height 1024 --iterations 32 --draws 32

# Offscreen render demo with Shader Timeline enabled
scripts/xtrace --gpu --shader-timeline -d 8 build/examples/metal_render_demo --seconds 4 --width 1024 --height 1024 --iterations 32 --draws 32

# Windowed MTKView demo, Metal System Trace
scripts/xtrace --gpu -d 8 build/examples/metal_window_demo --seconds 4 --width 960 --height 540 --draws 16 --fps 60

# Windowed MTKView demo with Shader Timeline enabled
scripts/xtrace --gpu --shader-timeline -d 8 build/examples/metal_window_demo --seconds 4 --width 960 --height 540 --draws 16 --fps 60

# Fixed PBR scene with Shader Timeline enabled
scripts/xtrace --gpu --shader-timeline -d 8 build/examples/metal_pbr_shadow_demo --seconds 4 --width 1280 --height 720 --fps 60 --shadow-map-size 2048

# Game Performance template
scripts/xtrace -t 'Game Performance' -d 8 build/examples/metal_window_demo --seconds 4

# Custom Metal instrument set
scripts/xtrace --instrument GPU --instrument 'Metal Application' -d 8 build/examples/metal_window_demo --seconds 4
```

The windowed demo is the one to use when you want to inspect rows like:
- `ca-client-present-request`
- `ca-client-presented-handler`
- `metal-io-surface-access`
- GPU ownership involving `WindowServer`

## Analyze an existing trace

```bash
python3 scripts/trace-gpu.py /path/to/recording.trace
python3 scripts/trace-gpu.py /path/to/recording.trace --json > metal_report.json

# Shader-profiler tooling (best when recorded with --shader-timeline)
python3 scripts/trace-shader.py info /path/to/recording.trace
python3 scripts/trace-shader.py hotspots /path/to/recording.trace
python3 scripts/trace-shader.py callsites /path/to/recording.trace
python3 scripts/trace-shader.py flamegraph /path/to/recording.trace -o shader.svg
scripts/trace-shader-flamegraph.sh /path/to/recording.trace -o shader.svg      # static SVG
scripts/trace-shader-speedscope.sh /path/to/recording.trace                     # interactive speedscope
scripts/trace-shader-speedscope.sh -o shader.folded /path/to/recording.trace    # keep the folded stacks too

# GPU trace bundle inspection from MTLCaptureManager output
python3 scripts/trace-gputrace.py info /path/to/capture.gputrace
python3 scripts/trace-gputrace.py resources /path/to/capture.gputrace
python3 scripts/trace-gputrace.py report /path/to/capture.gputrace -o capture_report.html
```
