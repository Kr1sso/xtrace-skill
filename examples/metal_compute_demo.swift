import Foundation
import Metal

struct Uniforms {
    var elementCount: UInt32
    var iterations: UInt32
    var seed: UInt32
    var padding: UInt32 = 0
}

struct Config {
    var seconds: Double = 6.0
    var elementCount: Int = 1 << 20
    var iterations: Int = 96
    var capturePath: String?
    var captureOnly: Bool = false
}

enum DemoError: Error, CustomStringConvertible {
    case usage(String)
    case noDevice
    case libraryBuildFailed(String)
    case pipelineBuildFailed(String)
    case bufferAllocationFailed
    case commandQueueFailed
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
            return "Failed to compile the Metal shader: \(message)"
        case .pipelineBuildFailed(let message):
            return "Failed to create the compute pipeline: \(message)"
        case .bufferAllocationFailed:
            return "Failed to allocate the working Metal buffer."
        case .commandQueueFailed:
            return "Failed to create a Metal command queue."
        case .commandBufferFailed:
            return "Failed to create a Metal command buffer."
        case .encoderFailed:
            return "Failed to create a Metal compute encoder."
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

struct Uniforms {
    uint elementCount;
    uint iterations;
    uint seed;
    uint padding;
};

kernel void stressKernel(device float *values [[buffer(0)]],
                         constant Uniforms &uniforms [[buffer(1)]],
                         uint gid [[thread_position_in_grid]]) {
    if (gid >= uniforms.elementCount) {
        return;
    }

    float x = values[gid] + float((gid ^ uniforms.seed) & 1023u) * 0.0009765625f;
    float y = float((gid * 17u + uniforms.seed) & 4095u) * 0.000244140625f + 0.5f;

    for (uint i = 0; i < uniforms.iterations; ++i) {
        x = fma(x, 1.61803398875f, y);
        y = y * 1.32471795724f + x * 0.000381966f;
        y = y - floor(y);
        x = sin(x) * cos(y) + sqrt(fabs(x) + 1.0f);
    }

    values[gid] = x + y;
}
"""

func printUsage() {
    let usage = """
    Usage: metal_compute_demo [--seconds N] [--elements N] [--iterations N] [--capture PATH] [--capture-only PATH]

      --seconds N        Approximate runtime in seconds (default: 6.0)
      --elements N       Number of float elements processed per dispatch (default: 1048576)
      --iterations N     Inner loop iterations in the shader (default: 96)
      --capture PATH     Capture the first dispatch to a .gputrace file and continue running
      --capture-only PATH
                         Capture the first dispatch to a .gputrace file, then exit immediately
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
            guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]), seconds > 0 else {
                throw DemoError.usage("--seconds expects a positive number")
            }
            config.seconds = seconds
            index += 2
        case "--elements":
            guard index + 1 < arguments.count, let elementCount = Int(arguments[index + 1]), elementCount > 0 else {
                throw DemoError.usage("--elements expects a positive integer")
            }
            config.elementCount = elementCount
            index += 2
        case "--iterations":
            guard index + 1 < arguments.count, let iterations = Int(arguments[index + 1]), iterations > 0 else {
                throw DemoError.usage("--iterations expects a positive integer")
            }
            config.iterations = iterations
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

    guard let function = library.makeFunction(name: "stressKernel") else {
        throw DemoError.libraryBuildFailed("Could not find stressKernel in compiled library")
    }

    let pipeline: MTLComputePipelineState
    do {
        pipeline = try device.makeComputePipelineState(function: function)
    } catch {
        throw DemoError.pipelineBuildFailed(String(describing: error))
    }

    guard let commandQueue = device.makeCommandQueue() else {
        throw DemoError.commandQueueFailed
    }
    commandQueue.label = "Compute Demo Queue"

    let captureManager = MTLCaptureManager.shared()
    if config.capturePath != nil && !captureManager.supportsDestination(.gpuTraceDocument) {
        throw DemoError.captureUnavailable
    }

    let byteCount = config.elementCount * MemoryLayout<Float>.stride
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw DemoError.bufferAllocationFailed
    }
    buffer.label = "Compute Values Buffer"

    let values = buffer.contents().bindMemory(to: Float.self, capacity: config.elementCount)
    for index in 0..<config.elementCount {
        values[index] = Float(index % 2048) * 0.001
    }

    let threadWidth = max(pipeline.threadExecutionWidth, 1)
    let requestedWidth = min(pipeline.maxTotalThreadsPerThreadgroup, threadWidth * 8)
    let threadgroupWidth = max(threadWidth, requestedWidth - (requestedWidth % threadWidth))
    let threadsPerThreadgroup = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
    let threadsPerGrid = MTLSize(width: config.elementCount, height: 1, depth: 1)

    print("Metal device: \(device.name)")
    print("Dispatch shape: elements=\(config.elementCount), iterations=\(config.iterations), runtime≈\(String(format: "%.2f", config.seconds))s")
    print("Pipeline: threadExecutionWidth=\(pipeline.threadExecutionWidth), maxThreadsPerThreadgroup=\(pipeline.maxTotalThreadsPerThreadgroup), using=\(threadgroupWidth)")
    if let capturePath = config.capturePath {
        print("GPU capture target: \(capturePath) (\(config.captureOnly ? "capture-only" : "capture + continue"))")
    }

    let start = CFAbsoluteTimeGetCurrent()
    var dispatchCount = 0

    while CFAbsoluteTimeGetCurrent() - start < config.seconds {
        let shouldCaptureDispatch = dispatchCount == 0 && config.capturePath != nil
        if shouldCaptureDispatch, let capturePath = config.capturePath {
            do {
                try startGPUCapture(manager: captureManager, device: device, outputPath: capturePath, label: "first dispatch")
            } catch {
                throw DemoError.captureFailed(String(describing: error))
            }
        }

        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError(DemoError.commandBufferFailed.description)
            }
            commandBuffer.label = "Compute Dispatch \(dispatchCount)"

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                fatalError(DemoError.encoderFailed.description)
            }
            encoder.label = "Stress Kernel Encoder"

            var uniforms = Uniforms(
                elementCount: UInt32(config.elementCount),
                iterations: UInt32(config.iterations),
                seed: UInt32(dispatchCount)
            )

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            withUnsafeBytes(of: &uniforms) { bytes in
                encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        if shouldCaptureDispatch, let capturePath = config.capturePath {
            finishGPUCapture(manager: captureManager, outputPath: capturePath)
            if config.captureOnly {
                dispatchCount += 1
                break
            }
        }

        dispatchCount += 1
    }

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    let sampleStride = max(1, config.elementCount / 4096)
    var checksum = Double.zero
    var sampledCount = 0
    for index in stride(from: 0, to: config.elementCount, by: sampleStride) {
        checksum += Double(values[index])
        sampledCount += 1
    }

    print("Completed \(dispatchCount) command buffers in \(String(format: "%.3f", elapsed))s")
    print("Sampled checksum (\(sampledCount) values): \(String(format: "%.6f", checksum))")
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
