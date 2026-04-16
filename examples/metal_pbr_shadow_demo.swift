import Foundation
import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct Material {
    var baseColor: SIMD3<Float>
    var roughness: Float
    var metallic: Float
}

struct FrameUniforms {
    var viewProjectionMatrix: simd_float4x4
    var lightViewProjectionMatrix: simd_float4x4
    var cameraPosition: SIMD3<Float>
    var shadowBias: Float
    var lightDirection: SIMD3<Float>
    var shadowTexelSize: SIMD2<Float>
    var lightColor: SIMD3<Float>
    var ambientIntensity: Float
}

struct DrawUniforms {
    var modelMatrix: simd_float4x4
    var normalMatrix: simd_float3x3
    var baseColor: SIMD3<Float>
    var roughness: Float
    var metallic: Float
    var padding: SIMD3<Float> = .zero
}

struct Config {
    var seconds: Double = 6.0
    var width: Int = 1280
    var height: Int = 720
    var preferredFPS: Int = 60
    var shadowMapSize: Int = 2048
    var capturePath: String?
    var captureOnly: Bool = false
}

enum DemoError: Error, CustomStringConvertible {
    case usage(String)
    case noDevice
    case libraryBuildFailed(String)
    case pipelineBuildFailed(String)
    case commandQueueFailed
    case bufferBuildFailed(String)
    case textureBuildFailed(String)
    case samplerBuildFailed
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
        case .bufferBuildFailed(let message):
            return "Failed to build GPU buffers: \(message)"
        case .textureBuildFailed(let message):
            return "Failed to create GPU textures: \(message)"
        case .samplerBuildFailed:
            return "Failed to create the shadow sampler state."
        case .captureUnavailable:
            return "GPU trace capture is unavailable. Re-run with MTL_CAPTURE_ENABLED=1 or enable MetalCaptureEnabled in the app environment."
        case .captureFailed(let message):
            return "Failed to create the GPU trace: \(message)"
        }
    }
}

struct MeshBuffers {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let material: Material
    let modelMatrix: simd_float4x4
    let label: String
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

func printUsage() {
    let usage = """
    Usage: metal_pbr_shadow_demo [--seconds N] [--width N] [--height N] [--fps N] [--shadow-map-size N] [--capture PATH] [--capture-only PATH]

      --seconds N           Approximate runtime in seconds (default: 6.0)
      --width N             Window width in points (default: 1280)
      --height N            Window height in points (default: 720)
      --fps N               Preferred MTKView FPS (default: 60)
      --shadow-map-size N   Shadow-map resolution (default: 2048)
      --capture PATH        Capture the first presented frame to a .gputrace file and continue running
      --capture-only PATH   Capture the first presented frame to a .gputrace file, then exit immediately
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
        case "--fps":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--fps expects a positive integer")
            }
            config.preferredFPS = value
            index += 2
        case "--shadow-map-size":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                throw DemoError.usage("--shadow-map-size expects a positive integer")
            }
            config.shadowMapSize = value
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

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float3 normal;
};

struct FrameUniforms {
    float4x4 viewProjectionMatrix;
    float4x4 lightViewProjectionMatrix;
    float3 cameraPosition;
    float shadowBias;
    float3 lightDirection;
    float2 shadowTexelSize;
    float3 lightColor;
    float ambientIntensity;
};

struct DrawUniforms {
    float4x4 modelMatrix;
    float3x3 normalMatrix;
    float3 baseColor;
    float roughness;
    float metallic;
    float3 padding;
};

struct ShadowVertexOut {
    float4 position [[position]];
};

struct MainVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float4 shadowPosition;
};

float distributionGGX(float3 N, float3 H, float roughness) {
    float alpha = max(roughness * roughness, 0.04f);
    float alpha2 = alpha * alpha;
    float NdotH = max(dot(N, H), 0.0f);
    float denom = NdotH * NdotH * (alpha2 - 1.0f) + 1.0f;
    return alpha2 / max(M_PI_F * denom * denom, 1e-4f);
}

float geometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0f;
    float k = (r * r) * 0.125f;
    return NdotV / mix(NdotV, 1.0f, k);
}

float geometrySmith(float3 N, float3 V, float3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0f);
    float NdotL = max(dot(N, L), 0.0f);
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

float3 fresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0f - F0) * pow(clamp(1.0f - cosTheta, 0.0f, 1.0f), 5.0f);
}

float shadowVisibility(float4 shadowPosition,
                       depth2d<float> shadowMap,
                       sampler shadowSampler,
                       float2 texelSize,
                       float bias) {
    float3 shadowCoord = shadowPosition.xyz / max(shadowPosition.w, 1e-4f);
    float2 uv = shadowCoord.xy * 0.5f + 0.5f;
    // Metal texture coordinates originate in the top-left corner.
    uv.y = 1.0f - uv.y;
    // Metal clip-space depth is already in [0, 1] after perspective divide.
    float depth = shadowCoord.z;

    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f || depth <= 0.0f || depth >= 1.0f) {
        return 1.0f;
    }

    float visibility = 0.0f;
    constexpr float offsets[3] = { -1.0f, 0.0f, 1.0f };
    for (int y = 0; y < 3; ++y) {
        for (int x = 0; x < 3; ++x) {
            float2 offset = float2(offsets[x], offsets[y]) * texelSize;
            visibility += shadowMap.sample_compare(shadowSampler, uv + offset, depth - bias);
        }
    }

    return visibility / 9.0f;
}

vertex ShadowVertexOut shadowVertex(uint vertexID [[vertex_id]],
                                    const device Vertex *vertices [[buffer(0)]],
                                    constant FrameUniforms &frame [[buffer(1)]],
                                    constant DrawUniforms &draw [[buffer(2)]]) {
    ShadowVertexOut out;
    float4 worldPosition = draw.modelMatrix * float4(vertices[vertexID].position, 1.0f);
    out.position = frame.lightViewProjectionMatrix * worldPosition;
    return out;
}

vertex MainVertexOut pbrVertex(uint vertexID [[vertex_id]],
                               const device Vertex *vertices [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               constant DrawUniforms &draw [[buffer(2)]]) {
    MainVertexOut out;
    float4 worldPosition = draw.modelMatrix * float4(vertices[vertexID].position, 1.0f);
    out.position = frame.viewProjectionMatrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.normal = normalize(draw.normalMatrix * vertices[vertexID].normal);
    out.shadowPosition = frame.lightViewProjectionMatrix * worldPosition;
    return out;
}

fragment float4 pbrFragment(MainVertexOut in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(1)]],
                            constant DrawUniforms &draw [[buffer(2)]],
                            depth2d<float> shadowMap [[texture(0)]],
                            sampler shadowSampler [[sampler(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPosition);
    float3 L = normalize(-frame.lightDirection);
    float3 H = normalize(V + L);

    float visibility = shadowVisibility(in.shadowPosition, shadowMap, shadowSampler, frame.shadowTexelSize, frame.shadowBias);

    float3 F0 = mix(float3(0.04f), draw.baseColor, draw.metallic);
    float3 F = fresnelSchlick(max(dot(H, V), 0.0f), F0);
    float NDF = distributionGGX(N, H, draw.roughness);
    float G = geometrySmith(N, V, L, draw.roughness);

    float NdotV = max(dot(N, V), 0.0f);
    float NdotL = max(dot(N, L), 0.0f);
    float3 numerator = NDF * G * F;
    float denominator = max(4.0f * NdotV * NdotL, 1e-4f);
    float3 specular = numerator / denominator;

    float3 kS = F;
    float3 kD = (1.0f - kS) * (1.0f - draw.metallic);
    float3 diffuse = kD * draw.baseColor / M_PI_F;
    float3 direct = (diffuse + specular) * frame.lightColor * visibility * NdotL;

    float3 ambient = draw.baseColor * frame.ambientIntensity * (1.0f - 0.5f * draw.metallic);
    float3 color = direct + ambient;

    color = color / (color + float3(1.0f));
    color = pow(color, float3(1.0f / 2.2f));
    return float4(color, 1.0f);
}
"""

func translationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    )
}

func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1.0 / tan(fovY * 0.5)
    let x = y / max(aspect, 0.001)
    let z = far / (near - far)
    return simd_float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
    )
}

func orthographicMatrix(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
    let rml = right - left
    let tmb = top - bottom
    let fmn = far - near
    return simd_float4x4(
        SIMD4<Float>(2.0 / rml, 0, 0, 0),
        SIMD4<Float>(0, 2.0 / tmb, 0, 0),
        SIMD4<Float>(0, 0, -1.0 / fmn, 0),
        SIMD4<Float>(-(right + left) / rml, -(top + bottom) / tmb, -near / fmn, 1)
    )
}

func lookAtMatrix(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let zAxis = simd_normalize(eye - target)
    let xAxis = simd_normalize(simd_cross(up, zAxis))
    let yAxis = simd_cross(zAxis, xAxis)

    return simd_float4x4(
        SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
        SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
        SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
        SIMD4<Float>(-simd_dot(xAxis, eye), -simd_dot(yAxis, eye), -simd_dot(zAxis, eye), 1)
    )
}

func normalMatrix(from modelMatrix: simd_float4x4) -> simd_float3x3 {
    simd_float3x3(
        SIMD3<Float>(modelMatrix.columns.0.x, modelMatrix.columns.0.y, modelMatrix.columns.0.z),
        SIMD3<Float>(modelMatrix.columns.1.x, modelMatrix.columns.1.y, modelMatrix.columns.1.z),
        SIMD3<Float>(modelMatrix.columns.2.x, modelMatrix.columns.2.y, modelMatrix.columns.2.z)
    )
}

func buildPlaneGeometry(size: Float) -> (vertices: [Vertex], indices: [UInt32]) {
    let half = size * 0.5
    let up = SIMD3<Float>(0, 1, 0)
    let vertices = [
        Vertex(position: SIMD3<Float>(-half, 0, -half), normal: up),
        Vertex(position: SIMD3<Float>( half, 0, -half), normal: up),
        Vertex(position: SIMD3<Float>( half, 0,  half), normal: up),
        Vertex(position: SIMD3<Float>(-half, 0,  half), normal: up),
    ]
    // Counter-clockwise when viewed from above (+Y) so the plane survives back-face culling.
    let indices: [UInt32] = [0, 2, 1, 0, 3, 2]
    return (vertices, indices)
}

func buildSphereGeometry(radius: Float, latitudeSegments: Int, longitudeSegments: Int) -> (vertices: [Vertex], indices: [UInt32]) {
    var vertices: [Vertex] = []
    var indices: [UInt32] = []

    for lat in 0...latitudeSegments {
        let v = Float(lat) / Float(latitudeSegments)
        let theta = v * Float.pi
        let sinTheta = sin(theta)
        let cosTheta = cos(theta)

        for lon in 0...longitudeSegments {
            let u = Float(lon) / Float(longitudeSegments)
            let phi = u * Float.pi * 2.0
            let sinPhi = sin(phi)
            let cosPhi = cos(phi)
            let normal = SIMD3<Float>(sinTheta * cosPhi, cosTheta, sinTheta * sinPhi)
            vertices.append(Vertex(position: normal * radius, normal: normal))
        }
    }

    let ring = longitudeSegments + 1
    for lat in 0..<latitudeSegments {
        for lon in 0..<longitudeSegments {
            let a = UInt32(lat * ring + lon)
            let b = UInt32((lat + 1) * ring + lon)
            let c = a + 1
            let d = b + 1
            indices.append(contentsOf: [a, b, c, c, b, d])
        }
    }

    return (vertices, indices)
}

func makeMesh(device: MTLDevice,
              vertices: [Vertex],
              indices: [UInt32],
              material: Material,
              modelMatrix: simd_float4x4,
              label: String) throws -> MeshBuffers {
    let vertexLength = vertices.count * MemoryLayout<Vertex>.stride
    let indexLength = indices.count * MemoryLayout<UInt32>.stride

    guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexLength, options: .storageModeShared) else {
        throw DemoError.bufferBuildFailed("Could not allocate \(label) vertex buffer")
    }
    vertexBuffer.label = "\(label) Vertex Buffer"

    guard let indexBuffer = device.makeBuffer(bytes: indices, length: indexLength, options: .storageModeShared) else {
        throw DemoError.bufferBuildFailed("Could not allocate \(label) index buffer")
    }
    indexBuffer.label = "\(label) Index Buffer"

    return MeshBuffers(
        vertexBuffer: vertexBuffer,
        indexBuffer: indexBuffer,
        indexCount: indices.count,
        material: material,
        modelMatrix: modelMatrix,
        label: label
    )
}

final class Renderer: NSObject, MTKViewDelegate {
    private let config: Config
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let shadowPipelineState: MTLRenderPipelineState
    private let mainPipelineState: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let shadowMap: MTLTexture
    private let shadowSampler: MTLSamplerState
    private let sphereMesh: MeshBuffers
    private let planeMesh: MeshBuffers
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
        commandQueue.label = "PBR Shadow Demo Queue"
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

        guard let shadowVertex = library.makeFunction(name: "shadowVertex"),
              let pbrVertex = library.makeFunction(name: "pbrVertex"),
              let pbrFragment = library.makeFunction(name: "pbrFragment") else {
            throw DemoError.libraryBuildFailed("Could not find one or more shader entry points")
        }

        let shadowPipelineDescriptor = MTLRenderPipelineDescriptor()
        shadowPipelineDescriptor.vertexFunction = shadowVertex
        shadowPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        do {
            shadowPipelineState = try device.makeRenderPipelineState(descriptor: shadowPipelineDescriptor)
        } catch {
            throw DemoError.pipelineBuildFailed("Shadow pipeline: \(error)")
        }

        let mainPipelineDescriptor = MTLRenderPipelineDescriptor()
        mainPipelineDescriptor.vertexFunction = pbrVertex
        mainPipelineDescriptor.fragmentFunction = pbrFragment
        mainPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        mainPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        do {
            mainPipelineState = try device.makeRenderPipelineState(descriptor: mainPipelineDescriptor)
        } catch {
            throw DemoError.pipelineBuildFailed("Main pipeline: \(error)")
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw DemoError.pipelineBuildFailed("Could not create depth-stencil state")
        }
        self.depthStencilState = depthStencilState

        let shadowDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: config.shadowMapSize,
            height: config.shadowMapSize,
            mipmapped: false
        )
        shadowDescriptor.storageMode = .private
        shadowDescriptor.usage = [.renderTarget, .shaderRead]
        guard let shadowMap = device.makeTexture(descriptor: shadowDescriptor) else {
            throw DemoError.textureBuildFailed("Could not create the shadow-map texture")
        }
        shadowMap.label = "Shadow Map Depth Texture"
        self.shadowMap = shadowMap

        let samplerDescriptor = MTLSamplerDescriptor()
        // Comparison samplers give more stable shadow tests and built-in filtered
        // comparisons for each PCF tap.
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
         samplerDescriptor.compareFunction = .lessEqual
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let shadowSampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw DemoError.samplerBuildFailed
        }
        self.shadowSampler = shadowSampler

        let plane = buildPlaneGeometry(size: 10.0)
        planeMesh = try makeMesh(
            device: device,
            vertices: plane.vertices,
            indices: plane.indices,
            material: Material(baseColor: SIMD3<Float>(0.58, 0.60, 0.66), roughness: 0.94, metallic: 0.0),
            modelMatrix: matrix_identity_float4x4,
            label: "Ground Plane"
        )

        let sphere = buildSphereGeometry(radius: 1.0, latitudeSegments: 48, longitudeSegments: 96)
        sphereMesh = try makeMesh(
            device: device,
            vertices: sphere.vertices,
            indices: sphere.indices,
            material: Material(baseColor: SIMD3<Float>(0.93, 0.36, 0.18), roughness: 0.24, metallic: 0.05),
            modelMatrix: translationMatrix(SIMD3<Float>(0.0, 1.08, 0.0)),
            label: "Hero Sphere"
        )
    }

    func logStartup() {
        let runtime = String(format: "%.2f", config.seconds)
        print("Metal device: \(device.name)")
        print("Scene: fixed PBR sphere over plane, directional light + shadow map")
        print("Window: \(config.width)x\(config.height), preferredFPS=\(config.preferredFPS), shadowMap=\(config.shadowMapSize), runtime≈\(runtime)s")
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
        commandBuffer.label = "PBR Shadow Frame \(frameIndex)"

        let drawableWidth = max(Float(view.drawableSize.width), 1.0)
        let drawableHeight = max(Float(view.drawableSize.height), 1.0)
        let frameUniforms = buildFrameUniforms(drawableWidth: drawableWidth, drawableHeight: drawableHeight)

        doShadowPass(commandBuffer: commandBuffer, frameUniforms: frameUniforms)
        doMainPass(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor, drawable: drawable, drawableWidth: drawableWidth, drawableHeight: drawableHeight, frameUniforms: frameUniforms)

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

    private func buildFrameUniforms(drawableWidth: Float, drawableHeight: Float) -> FrameUniforms {
        let cameraPosition = SIMD3<Float>(6.4, 2.65, 8.2)
        let target = SIMD3<Float>(0.0, 0.55, 0.0)
        let viewMatrix = lookAtMatrix(eye: cameraPosition, target: target, up: SIMD3<Float>(0, 1, 0))
        let projectionMatrix = perspectiveMatrix(fovY: 52.0 * .pi / 180.0, aspect: drawableWidth / drawableHeight, near: 0.1, far: 26.0)

        let lightDirection = simd_normalize(SIMD3<Float>(-0.45, -1.0, -0.35))
        let lightTarget = SIMD3<Float>(0.0, 0.75, 0.0)
        let lightPosition = lightTarget - lightDirection * 6.0
        let lightViewMatrix = lookAtMatrix(eye: lightPosition, target: lightTarget, up: SIMD3<Float>(0, 1, 0))
        let lightProjection = orthographicMatrix(left: -4.0, right: 4.0, bottom: -4.0, top: 4.0, near: 0.1, far: 12.0)

        return FrameUniforms(
            viewProjectionMatrix: projectionMatrix * viewMatrix,
            lightViewProjectionMatrix: lightProjection * lightViewMatrix,
            cameraPosition: cameraPosition,
            shadowBias: 0.004,
            lightDirection: lightDirection,
            shadowTexelSize: SIMD2<Float>(repeating: 1.0 / Float(config.shadowMapSize)),
            lightColor: SIMD3<Float>(1.0, 0.96, 0.90) * 6.5,
            ambientIntensity: 0.08
        )
    }

    private func doShadowPass(commandBuffer: MTLCommandBuffer, frameUniforms: FrameUniforms) {
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) else { return }
        encoder.label = "Shadow Map Pass"
        encoder.setRenderPipelineState(shadowPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setDepthBias(1.5, slopeScale: 2.0, clamp: 0.01)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(config.shadowMapSize), height: Double(config.shadowMapSize), znear: 0.0, zfar: 1.0))

        // Only the sphere is a shadow caster in this fixed scene. Omitting the
        // receiver plane avoids receiver self-shadowing that shows up as a large
        // rectangular dark patch matching the light frustum.
        drawShadowMesh(encoder: encoder, mesh: sphereMesh, frameUniforms: frameUniforms)
        encoder.endEncoding()
    }

    private func doMainPass(commandBuffer: MTLCommandBuffer,
                            renderPassDescriptor: MTLRenderPassDescriptor,
                            drawable: CAMetalDrawable,
                            drawableWidth: Float,
                            drawableHeight: Float,
                            frameUniforms: FrameUniforms) {
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        drawable.texture.label = "PBR Scene Drawable"

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.label = "Main Lighting Pass"
        encoder.setRenderPipelineState(mainPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(drawableWidth), height: Double(drawableHeight), znear: 0.0, zfar: 1.0))
        encoder.setFragmentTexture(shadowMap, index: 0)
        encoder.setFragmentSamplerState(shadowSampler, index: 0)

        drawMainMesh(encoder: encoder, mesh: planeMesh, frameUniforms: frameUniforms)
        drawMainMesh(encoder: encoder, mesh: sphereMesh, frameUniforms: frameUniforms)
        encoder.endEncoding()
        commandBuffer.present(drawable)
    }

    private func drawShadowMesh(encoder: MTLRenderCommandEncoder, mesh: MeshBuffers, frameUniforms: FrameUniforms) {
        var frameUniforms = frameUniforms
        var drawUniforms = buildDrawUniforms(mesh: mesh)
        encoder.pushDebugGroup(mesh.label)
        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &frameUniforms) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        withUnsafeBytes(of: &drawUniforms) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 2)
        }
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indexBuffer, indexBufferOffset: 0)
        encoder.popDebugGroup()
    }

    private func drawMainMesh(encoder: MTLRenderCommandEncoder, mesh: MeshBuffers, frameUniforms: FrameUniforms) {
        var frameUniforms = frameUniforms
        var drawUniforms = buildDrawUniforms(mesh: mesh)
        encoder.pushDebugGroup(mesh.label)
        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &frameUniforms) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        withUnsafeBytes(of: &drawUniforms) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 2)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
        }
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indexBuffer, indexBufferOffset: 0)
        encoder.popDebugGroup()
    }

    private func buildDrawUniforms(mesh: MeshBuffers) -> DrawUniforms {
        DrawUniforms(
            modelMatrix: mesh.modelMatrix,
            normalMatrix: normalMatrix(from: mesh.modelMatrix),
            baseColor: mesh.material.baseColor,
            roughness: mesh.material.roughness,
            metallic: mesh.material.metallic
        )
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
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "metal_pbr_shadow_demo"
            window.center()
            window.isReleasedWhenClosed = false

            let view = MTKView(frame: frame, device: device)
            view.clearColor = MTLClearColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .depth32Float
            view.sampleCount = 1
            view.preferredFramesPerSecond = config.preferredFPS
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.framebufferOnly = false
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
