import Foundation
import Metal

struct StressReport: Codable, Identifiable, Hashable {
    struct Sample: Codable, Hashable {
        var t: Double                // seconds since start
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fan: Double              // fastest fan, rpm
        var power: Double?           // system watts
        var cpuGflops: Double
        var gpuGflops: Double
    }

    var id = UUID()
    var date: Date
    var target: StressTest.Target
    var plannedSeconds: Double
    var seconds: Double
    /// nil when the run completed; otherwise why it stopped early.
    var endReason: String?
    var worstThermalState: String
    var samples: [Sample]

    var peakCPUTemp: Double? { samples.compactMap(\.cpuTemp).max() }
    var avgCPUTemp: Double? { Self.mean(samples.compactMap(\.cpuTemp)) }
    var peakGPUTemp: Double? { samples.compactMap(\.gpuTemp).max() }
    var avgGPUTemp: Double? { Self.mean(samples.compactMap(\.gpuTemp)) }
    var peakFan: Double { samples.map(\.fan).max() ?? 0 }
    var peakPower: Double? { samples.compactMap(\.power).max() }
    var avgPower: Double? { Self.mean(samples.compactMap(\.power)) }
    var avgCPUGflops: Double? { target == .gpu ? nil : Self.mean(samples.map(\.cpuGflops)) }
    var avgGPUGflops: Double? { target == .cpu ? nil : Self.mean(samples.map(\.gpuGflops)) }

    /// Seconds until the fans started, nil if they never ran. Zero means they were already running.
    var fanSpinUp: Double? {
        guard let first = samples.first else { return nil }
        if first.fan > 0 { return 0 }
        return samples.first { $0.fan > 0 }?.t
    }

    /// Late-run score as a percentage of the first 30 s. Well below 100% suggests thermal throttling.
    func sustained(_ score: KeyPath<Sample, Double>) -> Double? {
        let lastWindow = min(60, seconds / 2)
        guard let early = Self.mean(samples.filter { $0.t <= 30 }.map { $0[keyPath: score] }), early > 0,
              let late = Self.mean(samples.filter { $0.t >= seconds - lastWindow }.map { $0[keyPath: score] })
        else { return nil }
        return late / early * 100
    }

    private static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}

/// Runs a CPU and/or GPU load and records temperatures, fans, power and throughput while it runs.
@MainActor
final class StressTest: ObservableObject {
    enum Target: String, Codable, CaseIterable, Identifiable {
        case cpu = "CPU", gpu = "GPU", both = "CPU + GPU"
        var id: String { rawValue }
    }

    struct Live {
        let start: Date
        let duration: TimeInterval
        let target: Target
        var cpuGflops: Double = 0
        var gpuGflops: Double = 0
        var elapsed: TimeInterval { Date().timeIntervalSince(start) }
    }

    static let abortTemperature = 105.0
    private static let maxReports = 10

    @Published private(set) var live: Live?
    @Published private(set) var reports: [StressReport] = []
    @Published private(set) var lastError: String?

    private unowned let store: MonitorStore
    private var load: LoadGenerator?
    private var samples: [StressReport.Sample] = []
    private var lastCount: (cpu: Double, gpu: Double, t: Date)?
    private var worstThermal = ProcessInfo.ThermalState.nominal
    private let fileURL: URL

    init(store: MonitorStore) {
        self.store = store
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TempMonitor/stress-reports.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode([StressReport].self, from: data) {
            reports = saved
        }
    }

    func start(target: Target, minutes: Int) {
        guard live == nil else { return }
        do {
            let generator = try LoadGenerator(cpu: target != .gpu, gpu: target != .cpu)
            generator.start()
            load = generator
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        samples = []
        worstThermal = store.thermalState
        lastCount = (0, 0, Date())
        live = Live(start: Date(), duration: TimeInterval(minutes * 60), target: target)
    }

    /// Called by the store after each refresh.
    func sample() {
        guard var run = live, let load, let last = lastCount else { return }
        let now = Date()
        let (cpu, gpu) = load.counts
        let dt = now.timeIntervalSince(last.t)
        guard dt > 0 else { return }
        run.cpuGflops = (cpu - last.cpu) / dt / 1e9
        run.gpuGflops = (gpu - last.gpu) / dt / 1e9
        lastCount = (cpu, gpu, now)
        live = run

        if store.thermalState.rawValue > worstThermal.rawValue { worstThermal = store.thermalState }
        let fan = store.fans.map(\.rpm).max() ?? 0
        let power = store.power.map { $0.system ?? $0.cpu + $0.gpu }
        samples.append(.init(t: run.elapsed, cpuTemp: store.summary(for: .cpu)?.hottest, gpuTemp: store.summary(for: .gpu)?.hottest,
                             fan: fan, power: power, cpuGflops: run.cpuGflops, gpuGflops: run.gpuGflops))

        if let hottest = store.readings.map(\.celsius).max(), hottest >= Self.abortTemperature {
            stop(reason: String(format: "Stopped at %.0f °C (safety limit)", hottest))
        } else if store.thermalState == .critical {
            stop(reason: "Stopped: thermal state critical")
        } else if run.elapsed >= run.duration {
            stop(reason: nil)
        }
    }

    /// Ends the run and saves a report. `reason` is nil for a run that completed normally.
    func stop(reason: String?) {
        guard let run = live else { return }
        load?.stop()
        load = nil
        live = nil
        guard !samples.isEmpty else { return }

        let report = StressReport(date: run.start, target: run.target, plannedSeconds: run.duration,
                                  seconds: min(run.elapsed, run.duration), endReason: reason,
                                  worstThermalState: worstThermal.title, samples: samples)
        reports.insert(report, at: 0)
        if reports.count > Self.maxReports { reports.removeLast(reports.count - Self.maxReports) }
        save()
    }

    func clearReports() {
        reports = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(reports) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Background CPU threads and a Metal compute loop that count the floating-point work they finish.
private final class LoadGenerator: @unchecked Sendable {
    enum LoadError: LocalizedError {
        case noGPU, shader(String)
        var errorDescription: String? {
            switch self {
            case .noGPU: return "No Metal GPU available."
            case .shader(let msg): return "GPU load failed to start: \(msg)"
            }
        }
    }

    private let lock = NSLock()
    private var stopped = false
    private var cpuFlops: Double = 0
    private var gpuFlops: Double = 0
    private var sink: Double = 0

    private let runCPU: Bool
    private let gpu: (queue: MTLCommandQueue, pipeline: MTLComputePipelineState, buffer: MTLBuffer)?

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

    init(cpu: Bool, gpu useGPU: Bool) throws {
        runCPU = cpu
        guard useGPU else { gpu = nil; return }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw LoadError.noGPU }
        do {
            let library = try device.makeLibrary(source: Self.kernelSource, options: nil)
            guard let fn = library.makeFunction(name: "burn") else { throw LoadError.shader("missing kernel") }
            let pipeline = try device.makeComputePipelineState(function: fn)
            guard let buffer = device.makeBuffer(length: Self.gpuThreads * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate)
            else { throw LoadError.shader("buffer allocation failed") }
            gpu = (queue, pipeline, buffer)
        } catch let e as LoadError {
            throw e
        } catch {
            throw LoadError.shader(error.localizedDescription)
        }
    }

    var counts: (cpu: Double, gpu: Double) {
        lock.lock(); defer { lock.unlock() }
        return (cpuFlops, gpuFlops)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func start() {
        if runCPU {
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                let t = Thread { [self] in cpuLoop() }
                t.qualityOfService = .userInitiated
                t.start()
            }
        }
        if gpu != nil {
            let t = Thread { [self] in gpuLoop() }
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func cpuLoop() {
        // Eight independent fused multiply-add chains keep the FP pipelines full.
        let chunk = 20_000_000
        let m = 0.9999999, c = 0.0000001
        var a0 = 1.0, a1 = 1.1, a2 = 1.2, a3 = 1.3, a4 = 1.4, a5 = 1.5, a6 = 1.6, a7 = 1.7
        while !isStopped {
            for _ in 0..<chunk {
                a0 = a0 * m + c; a1 = a1 * m + c; a2 = a2 * m + c; a3 = a3 * m + c
                a4 = a4 * m + c; a5 = a5 * m + c; a6 = a6 * m + c; a7 = a7 * m + c
            }
            lock.lock()
            cpuFlops += Double(chunk) * 8 * 2
            lock.unlock()
        }
        lock.lock()
        sink += a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7
        lock.unlock()
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
                    lock.lock(); gpuFlops += flopsPerDispatch; lock.unlock()
                }
            }
        }
    }
}
