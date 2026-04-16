import Foundation
import Metal
import simd

struct Vertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

struct FragmentUniforms {
    var phase: Float
    var iterations: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

struct Config {
    var seconds: Double = 4.0
    var width: Int = 2048
    var height: Int = 2048
    var iterations: Int = 64
    var drawsPerFrame: Int = 128
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
    case textureFailed
    case commandBufferFailed
    case encoderFailed
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
        case .textureFailed:
            return "Failed to create render target texture."
        case .commandBufferFailed:
            return "Failed to create command buffer."
        case .encoderFailed:
            return "Failed to create render encoder."
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
    float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FragmentUniforms {
    float phase;
    uint iterations;
    uint padding0;
    uint padding1;
};

vertex VertexOut fullscreenVertex(uint vertexID [[vertex_id]],
                                  const device Vertex *vertices [[buffer(0)]]) {
    VertexOut out;
    Vertex v = vertices[vertexID];
    out.position = float4(v.position, 0.0, 1.0);
    out.uv = v.uv;
    return out;
}

fragment float4 proceduralFragment(VertexOut in [[stage_in]],
                                   constant FragmentUniforms &uniforms [[buffer(0)]]) {
    float2 z = in.uv * 2.0f - 1.0f;
    float accum = 0.0f;

    for (uint i = 0; i < uniforms.iterations; ++i) {
        float t = uniforms.phase + float(i) * 0.021f;
        z = float2(
            sin(z.x * 1.31f + z.y * 0.73f + t),
            cos(z.y * 1.17f - z.x * 0.29f - t)
        );
        accum += dot(z, z);
        z += float2(0.002f, -0.001f) * accum;
    }

    float r = fract(accum * 0.071f + in.uv.x * 1.3f);
    float g = fract(accum * 0.049f + in.uv.y * 1.7f);
    float b = fract(accum * 0.031f + (in.uv.x + in.uv.y) * 0.9f);
    return float4(r, g, b, 1.0f);
}
"""

func printUsage() {
    let usage = """
    Usage: metal_render_demo [--seconds N] [--width N] [--height N] [--iterations N] [--draws N] [--capture PATH] [--capture-only PATH]

      --seconds N        Approximate runtime in seconds (default: 4.0)
      --width N          Offscreen render target width (default: 2048)
      --height N         Offscreen render target height (default: 2048)
      --iterations N     Inner fragment loop iterations (default: 64)
      --draws N          Fullscreen draws per command buffer (default: 128)
      --capture PATH     Capture the first frame to a .gputrace file and continue running
      --capture-only PATH
                         Capture the first frame to a .gputrace file, then exit immediately
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
        case "--iterations":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--iterations expects a positive integer")
            }
            config.iterations = value
            index += 2
        case "--draws":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--draws expects a positive integer")
            }
            config.drawsPerFrame = value
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
        Vertex(position: SIMD2<Float>(-1.0, -1.0), uv: SIMD2<Float>(0.0, 0.0)),
        Vertex(position: SIMD2<Float>(3.0, -1.0), uv: SIMD2<Float>(2.0, 0.0)),
        Vertex(position: SIMD2<Float>(-1.0, 3.0), uv: SIMD2<Float>(0.0, 2.0)),
    ]
}

func runDemo(config: Config) throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw DemoError.noDevice
    }

    let library: MTLLibrary
    do {
        library = try device.makeLibrary(source: shaderSource, options: nil)
    } catch {
        throw DemoError.libraryBuildFailed(String(describing: error))
    }

    guard
        let vertexFunction = library.makeFunction(name: "fullscreenVertex"),
        let fragmentFunction = library.makeFunction(name: "proceduralFragment")
    else {
        throw DemoError.libraryBuildFailed("Could not find fullscreenVertex/proceduralFragment")
    }

    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = vertexFunction
    pipelineDescriptor.fragmentFunction = fragmentFunction
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

    let pipeline: MTLRenderPipelineState
    do {
        pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    } catch {
        throw DemoError.pipelineBuildFailed(String(describing: error))
    }

    guard let commandQueue = device.makeCommandQueue() else {
        throw DemoError.commandQueueFailed
    }
    commandQueue.label = "Render Demo Queue"

    let captureManager = MTLCaptureManager.shared()
    if config.capturePath != nil && !captureManager.supportsDestination(.gpuTraceDocument) {
        throw DemoError.captureUnavailable
    }

    let vertices = buildVertices()
    let vertexBufferLength = vertices.count * MemoryLayout<Vertex>.stride
    guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexBufferLength, options: .storageModeShared) else {
        throw DemoError.vertexBufferFailed
    }
    vertexBuffer.label = "Fullscreen Triangle Vertices"

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: config.width,
        height: config.height,
        mipmapped: false
    )
    textureDescriptor.storageMode = .private
    textureDescriptor.usage = [.renderTarget, .shaderRead]

    guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
        throw DemoError.textureFailed
    }
    texture.label = "Offscreen Target Texture"

    print("Metal device: \(device.name)")
    print("Render target: \(config.width)x\(config.height), iterations=\(config.iterations), draws/frame=\(config.drawsPerFrame), runtime≈\(String(format: "%.2f", config.seconds))s")
    if let capturePath = config.capturePath {
        print("GPU capture target: \(capturePath) (\(config.captureOnly ? "capture-only" : "capture + continue"))")
    }

    let start = CFAbsoluteTimeGetCurrent()
    var frameIndex = 0

    while CFAbsoluteTimeGetCurrent() - start < config.seconds {
        let shouldCaptureFrame = frameIndex == 0 && config.capturePath != nil
        if shouldCaptureFrame, let capturePath = config.capturePath {
            do {
                try startGPUCapture(manager: captureManager, device: device, outputPath: capturePath, label: "first frame")
            } catch {
                throw DemoError.captureFailed(String(describing: error))
            }
        }

        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError(DemoError.commandBufferFailed.description)
            }
            commandBuffer.label = "Render Frame \(frameIndex)"

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double((frameIndex % 17)) / 17.0,
                green: Double((frameIndex % 23)) / 23.0,
                blue: Double((frameIndex % 29)) / 29.0,
                alpha: 1.0
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                fatalError(DemoError.encoderFailed.description)
            }
            encoder.label = "Procedural Triangle Pass"
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(config.width), height: Double(config.height), znear: 0, zfar: 1))

            var uniforms = FragmentUniforms(
                phase: Float(frameIndex) * 0.013,
                iterations: UInt32(config.iterations)
            )

            for drawIndex in 0..<config.drawsPerFrame {
                uniforms.phase = Float(frameIndex * config.drawsPerFrame + drawIndex) * 0.013
                withUnsafeBytes(of: &uniforms) { bytes in
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }

            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        if shouldCaptureFrame, let capturePath = config.capturePath {
            finishGPUCapture(manager: captureManager, outputPath: capturePath)
            if config.captureOnly {
                frameIndex += 1
                break
            }
        }

        frameIndex += 1
    }

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print("Completed \(frameIndex) render command buffers in \(String(format: "%.3f", elapsed))s")
    print("Final texture label: \(texture.label ?? "<none>")")
}

do {
    let config = try parseConfig()
    try runDemo(config: config)
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
