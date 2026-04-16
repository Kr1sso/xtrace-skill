import Foundation
import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

struct Vertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

struct VertexUniforms {
    var time: Float
    var aspect: Float
    var drawIndex: Float
    var scale: Float
}

struct FragmentUniforms {
    var time: Float
    var drawIndex: Float
    var width: Float
    var height: Float
}

struct Config {
    var seconds: Double = 6.0
    var width: Int = 1280
    var height: Int = 720
    var drawsPerFrame: Int = 32
    var preferredFPS: Int = 120
    var capturePath: String?
    var captureOnly: Bool = false
}

enum DemoError: Error, CustomStringConvertible {
    case usage(String)
    case noDevice
    case libraryBuildFailed(String)
    case pipelineBuildFailed(String)
    case commandQueueFailed
    case vertexBufferFailed
    case captureUnavailable
    case captureFailed(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .noDevice:
            return "No Metal device was available."
        case .libraryBuildFailed(let message):
            return "Failed to compile Metal shaders: \(message)"
        case .pipelineBuildFailed(let message):
            return "Failed to create render pipeline: \(message)"
        case .commandQueueFailed:
            return "Failed to create Metal command queue."
        case .vertexBufferFailed:
            return "Failed to create vertex buffer."
        case .captureUnavailable:
            return "GPU trace capture is unavailable. Re-run with MTL_CAPTURE_ENABLED=1 or enable MetalCaptureEnabled in the app environment."
        case .captureFailed(let message):
            return "Failed to create the GPU trace: \(message)"
        }
    }
}

func normalizedCapturePath(_ value: String) -> String {
    value.hasSuffix(".gputrace") ? value : value + ".gputrace"
}

func startGPUCapture(manager: MTLCaptureManager, device: MTLDevice, outputPath: String, label: String) throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let descriptor = MTLCaptureDescriptor()
    descriptor.captureObject = device
    descriptor.destination = .gpuTraceDocument
    descriptor.outputURL = outputURL
    try manager.startCapture(with: descriptor)
    print("Started GPU capture (\(label)) → \(outputURL.path)")
}

func finishGPUCapture(manager: MTLCaptureManager, outputPath: String) {
    guard manager.isCapturing else { return }
    manager.stopCapture()
    print("Saved GPU capture → \(outputPath)")
}

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float4 color;
};

struct VertexUniforms {
    float time;
    float aspect;
    float drawIndex;
    float scale;
};

struct FragmentUniforms {
    float time;
    float drawIndex;
    float width;
    float height;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float drawIndex;
};

vertex VertexOut windowVertex(uint vertexID [[vertex_id]],
                              const device Vertex *vertices [[buffer(0)]],
                              constant VertexUniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    Vertex v = vertices[vertexID];

    float angle = uniforms.time * 0.7 + uniforms.drawIndex * 0.19;
    float2x2 rot = float2x2(float2(cos(angle), -sin(angle)),
                            float2(sin(angle),  cos(angle)));

    float2 pos = rot * (v.position * uniforms.scale);
    pos.x /= max(uniforms.aspect, 0.001);

    float radius = 0.15 + 0.012 * fmod(uniforms.drawIndex, 11.0);
    float2 center = float2(cos(uniforms.drawIndex * 0.29 + uniforms.time * 0.8),
                           sin(uniforms.drawIndex * 0.23 - uniforms.time * 0.6)) * radius;

    out.position = float4(pos + center, 0.0, 1.0);
    out.color = v.color;
    out.uv = v.position * 0.5 + 0.5;
    out.drawIndex = uniforms.drawIndex;
    return out;
}

fragment float4 windowFragment(VertexOut in [[stage_in]],
                               constant FragmentUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    float wave = 0.0;

    for (uint i = 0; i < 24; ++i) {
        float t = uniforms.time * 0.8 + float(i) * 0.11 + uniforms.drawIndex * 0.07;
        wave += sin(dot(uv, float2(1.7 + 0.01 * float(i), 2.3 - 0.02 * float(i))) + t);
    }

    wave = wave / 24.0;
    float vignette = smoothstep(1.4, 0.2, length(uv));
    float scan = 0.5 + 0.5 * sin((uv.y * uniforms.height * 0.03) + uniforms.time * 4.0);

    float3 base = in.color.rgb * (0.6 + 0.4 * wave);
    base += float3(0.15 * scan, 0.08 * vignette, 0.12 * (1.0 - scan));
    base *= vignette;

    return float4(base, 1.0);
}
"""

func printUsage() {
    let usage = """
    Usage: metal_window_demo [--seconds N] [--width N] [--height N] [--draws N] [--fps N] [--capture PATH] [--capture-only PATH]

      --seconds N        Approximate runtime in seconds (default: 6.0)
      --width N          Window width in points (default: 1280)
      --height N         Window height in points (default: 720)
      --draws N          Triangle draws per frame (default: 32)
      --fps N            Preferred MTKView FPS (default: 120)
      --capture PATH     Capture the first presented frame to a .gputrace file and continue running
      --capture-only PATH
                         Capture the first presented frame to a .gputrace file, then exit immediately
    """
    print(usage)
}

func parseConfig() throws -> Config {
    var config = Config()
    var index = 1
    let arguments = CommandLine.arguments

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--help", "-h":
            throw DemoError.usage("")
        case "--seconds":
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--seconds expects a positive number")
            }
            config.seconds = value
            index += 2
        case "--width":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--width expects a positive integer")
            }
            config.width = value
            index += 2
        case "--height":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--height expects a positive integer")
            }
            config.height = value
            index += 2
        case "--draws":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--draws expects a positive integer")
            }
            config.drawsPerFrame = value
            index += 2
        case "--fps":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--fps expects a positive integer")
            }
            config.preferredFPS = value
            index += 2
        case "--capture":
            guard index + 1 < arguments.count else {
                throw DemoError.usage("--capture expects an output path")
            }
            config.capturePath = normalizedCapturePath(arguments[index + 1])
            config.captureOnly = false
            index += 2
        case "--capture-only":
            guard index + 1 < arguments.count else {
                throw DemoError.usage("--capture-only expects an output path")
            }
            config.capturePath = normalizedCapturePath(arguments[index + 1])
            config.captureOnly = true
            index += 2
        default:
            throw DemoError.usage("Unknown argument: \(argument)")
        }
    }

    return config
}

func buildVertices() -> [Vertex] {
    [
        Vertex(position: SIMD2<Float>(0.0, 0.72), color: SIMD4<Float>(1.0, 0.35, 0.25, 1.0)),
        Vertex(position: SIMD2<Float>(-0.68, -0.52), color: SIMD4<Float>(0.15, 0.85, 1.0, 1.0)),
        Vertex(position: SIMD2<Float>(0.68, -0.52), color: SIMD4<Float>(0.95, 0.9, 0.2, 1.0)),
    ]
}

final class Renderer: NSObject, MTKViewDelegate {
    private let config: Config
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let captureManager = MTLCaptureManager.shared()
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private let startTime = CFAbsoluteTimeGetCurrent()

    private var submittedFrames = 0
    private var completedFrames = 0
    private var didRequestShutdown = false
    private var lastLogSecond = -1

    var onFinish: ((Int, Int, Double) -> Void)?

    init(config: Config, device: MTLDevice) throws {
        self.config = config
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw DemoError.commandQueueFailed
        }
        commandQueue.label = "Window Demo Queue"
        self.commandQueue = commandQueue

        if config.capturePath != nil && !captureManager.supportsDestination(.gpuTraceDocument) {
            throw DemoError.captureUnavailable
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw DemoError.libraryBuildFailed(String(describing: error))
        }

        guard
            let vertexFunction = library.makeFunction(name: "windowVertex"),
            let fragmentFunction = library.makeFunction(name: "windowFragment")
        else {
            throw DemoError.libraryBuildFailed("Could not find windowVertex/windowFragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw DemoError.pipelineBuildFailed(String(describing: error))
        }

        let vertices = buildVertices()
        let bufferLength = vertices.count * MemoryLayout<Vertex>.stride
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: bufferLength, options: .storageModeShared) else {
            throw DemoError.vertexBufferFailed
        }
        vertexBuffer.label = "Window Vertices"
        self.vertexBuffer = vertexBuffer
    }

    func logStartup() {
        let runtime = String(format: "%.2f", config.seconds)
        print("Metal device: \(device.name)")
        print("Window: \(config.width)x\(config.height), draws/frame=\(config.drawsPerFrame), preferredFPS=\(config.preferredFPS), runtime≈\(runtime)s")
        if let capturePath = config.capturePath {
            print("GPU capture target: \(capturePath) (\(config.captureOnly ? "capture-only" : "capture + continue"))")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        print("Drawable size changed: \(Int(size.width))x\(Int(size.height))")
    }

    func draw(in view: MTKView) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let wholeSecond = Int(elapsed)
        if wholeSecond != lastLogSecond {
            lastLogSecond = wholeSecond
            print("elapsed=\(String(format: "%.2f", elapsed))s submitted=\(submittedFrames) completed=\(completedFrames)")
        }

        if elapsed >= config.seconds {
            requestShutdown()
            return
        }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        _ = inFlightSemaphore.wait(timeout: .distantFuture)

        let frameIndex = submittedFrames
        let shouldCaptureFrame = frameIndex == 0 && config.capturePath != nil
        if shouldCaptureFrame, let capturePath = config.capturePath {
            do {
                try startGPUCapture(manager: captureManager, device: device, outputPath: capturePath, label: "first presented frame")
            } catch {
                inFlightSemaphore.signal()
                fputs("Error: \(DemoError.captureFailed(String(describing: error)))\n", stderr)
                requestShutdown()
                return
            }
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            if shouldCaptureFrame, let capturePath = config.capturePath {
                finishGPUCapture(manager: captureManager, outputPath: capturePath)
            }
            inFlightSemaphore.signal()
            return
        }
        commandBuffer.label = "Window Frame \(frameIndex)"

        let time = Float(elapsed)
        let drawableWidth = max(Float(view.drawableSize.width), 1.0)
        let drawableHeight = max(Float(view.drawableSize.height), 1.0)
        let aspect = drawableWidth / drawableHeight

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.03 + Double((frameIndex % 13)) * 0.01,
            green: 0.05 + Double((frameIndex % 17)) * 0.006,
            blue: 0.08 + Double((frameIndex % 11)) * 0.008,
            alpha: 1.0
        )

        drawable.texture.label = "Window Drawable Texture"

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            if shouldCaptureFrame, let capturePath = config.capturePath {
                finishGPUCapture(manager: captureManager, outputPath: capturePath)
            }
            inFlightSemaphore.signal()
            return
        }
        encoder.label = "Presented Triangle Pass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setViewport(
            MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(drawableWidth),
                height: Double(drawableHeight),
                znear: 0,
                zfar: 1
            )
        )

        for drawIndex in 0..<config.drawsPerFrame {
            var vertexUniforms = VertexUniforms(
                time: time,
                aspect: aspect,
                drawIndex: Float(drawIndex),
                scale: 0.32 - Float(drawIndex % 7) * 0.015
            )
            var fragmentUniforms = FragmentUniforms(
                time: time,
                drawIndex: Float(drawIndex),
                width: drawableWidth,
                height: drawableHeight
            )

            withUnsafeBytes(of: &vertexUniforms) { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            withUnsafeBytes(of: &fragmentUniforms) { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.completedFrames += 1
            self?.inFlightSemaphore.signal()
        }
        commandBuffer.commit()
        if shouldCaptureFrame, let capturePath = config.capturePath {
            commandBuffer.waitUntilCompleted()
            finishGPUCapture(manager: captureManager, outputPath: capturePath)
            if config.captureOnly {
                submittedFrames += 1
                requestShutdown()
                return
            }
        }

        submittedFrames += 1
    }

    private func requestShutdown() {
        guard !didRequestShutdown else { return }
        didRequestShutdown = true

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        onFinish?(submittedFrames, completedFrames, elapsed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: Config
    private var window: NSWindow?
    private var renderer: Renderer?

    init(config: Config) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw DemoError.noDevice
            }

            let renderer = try Renderer(config: config, device: device)
            renderer.onFinish = { submitted, completed, elapsed in
                let formattedElapsed = String(format: "%.3f", elapsed)
                print("Completed \(submitted) submitted frames / \(completed) completed frames in \(formattedElapsed)s")
            }
            renderer.logStartup()
            self.renderer = renderer

            let frame = NSRect(x: 0, y: 0, width: config.width, height: config.height)
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            window.title = "metal_window_demo"
            window.center()
            window.isReleasedWhenClosed = false

            let view = MTKView(frame: frame, device: device)
            view.clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1.0)
            view.colorPixelFormat = .bgra8Unorm
            view.preferredFramesPerSecond = config.preferredFPS
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.framebufferOnly = true
            view.autoResizeDrawable = true
            view.delegate = renderer
            view.drawableSize = CGSize(width: config.width, height: config.height)
            if let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.displaySyncEnabled = true
                metalLayer.presentsWithTransaction = false
                metalLayer.allowsNextDrawableTimeout = true
                metalLayer.pixelFormat = .bgra8Unorm
            }

            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            self.window = window

            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("Error: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

do {
    let config = try parseConfig()
    let app = NSApplication.shared
    let delegate = AppDelegate(config: config)
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
} catch DemoError.usage(let message) {
    if !message.isEmpty {
        fputs("Error: \(message)\n\n", stderr)
    }
    printUsage()
    exit(message.isEmpty ? 0 : 1)
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
