import Foundation
import Metal

/// Floating-point operations completed so far.
struct FlopCounts: Equatable {
    var cpu: Double = 0
    var gpu: Double = 0
}

/// Something that loads the chip and counts the work it finishes.
protocol LoadGenerating: AnyObject {
    var counts: FlopCounts { get }
    func start()
    func stop()
}

/// Background CPU threads and a Metal compute loop that count the floating-point work they finish.
final class LoadGenerator: LoadGenerating, @unchecked Sendable {
    enum LoadError: LocalizedError {
        case noGPU, shader(String)
        var errorDescription: String? {
            switch self {
            case .noGPU: return "No Metal GPU available."
            case .shader(let msg): return "GPU load failed to start: \(msg)"
            }
        }
    }

    private struct GPUResources {
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let buffer: MTLBuffer
    }

    private let lock = NSLock()
    private var stopped = false
    private var flops = FlopCounts()
    /// Keeps the CPU loop's results alive so the compiler can't optimize the work away.
    private var sink: Double = 0

    private let runCPU: Bool
    private let gpu: GPUResources?

    private static let cpuChunk = 20_000_000
    private static let gpuThreads = 1 << 20
    private static let gpuIterations = 8192
    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float4 *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float4 a = buf[id], b = a + 1.0, m = float4(0.9999), c = float4(0.0001);
        for (int i = 0; i < \(gpuIterations); i++) { a = fma(a, m, c); b = fma(b, m, c); }
        buf[id] = a + b;
    }
    """

    init(target: StressTarget) throws {
        runCPU = target.loadsCPU
        gpu = target.loadsGPU ? try Self.makeGPUResources() : nil
    }

    var counts: FlopCounts {
        lock.withLock { flops }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    func start() {
        if runCPU {
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount { spawn(cpuLoop) }
        }
        if gpu != nil { spawn(gpuLoop) }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func spawn(_ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func cpuLoop() {
        // Eight independent fused multiply-add chains keep the FP pipelines full.
        let m = 0.9999999, c = 0.0000001
        var a0 = 1.0, a1 = 1.1, a2 = 1.2, a3 = 1.3, a4 = 1.4, a5 = 1.5, a6 = 1.6, a7 = 1.7
        let flopsPerChunk = Double(Self.cpuChunk) * 8 * 2
        while !isStopped {
            for _ in 0..<Self.cpuChunk {
                a0 = a0 * m + c; a1 = a1 * m + c; a2 = a2 * m + c; a3 = a3 * m + c
                a4 = a4 * m + c; a5 = a5 * m + c; a6 = a6 * m + c; a7 = a7 * m + c
            }
            lock.withLock { flops.cpu += flopsPerChunk }
        }
        lock.withLock { sink += a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 }
    }

    private func gpuLoop() {
        guard let gpu else { return }
        let flopsPerDispatch = Double(Self.gpuThreads) * Double(Self.gpuIterations) * 2 * 4 * 2
        let width = gpu.pipeline.maxTotalThreadsPerThreadgroup
        while !isStopped {
            autoreleasepool {
                guard let cb = gpu.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
                enc.setComputePipelineState(gpu.pipeline)
                enc.setBuffer(gpu.buffer, offset: 0, index: 0)
                enc.dispatchThreads(MTLSize(width: Self.gpuThreads, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
                if cb.status == .completed {
                    lock.withLock { flops.gpu += flopsPerDispatch }
                }
            }
        }
    }

    private static func makeGPUResources() throws -> GPUResources {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw LoadError.noGPU }
        do {
            let library = try device.makeLibrary(source: kernelSource, options: nil)
            guard let fn = library.makeFunction(name: "burn") else { throw LoadError.shader("missing kernel") }
            let pipeline = try device.makeComputePipelineState(function: fn)
            guard let buffer = device.makeBuffer(length: gpuThreads * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate)
            else { throw LoadError.shader("buffer allocation failed") }
            return GPUResources(queue: queue, pipeline: pipeline, buffer: buffer)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.shader(error.localizedDescription)
        }
    }
}
