import Foundation
import IOKit

struct UsageReading {
    var cpu: Double              // 0...100, all cores
    var performanceCores: Double
    var efficiencyCores: Double
    var gpu: Double?
}

struct MemoryReading {
    var used: Double             // bytes: app + wired + compressed (matches Activity Monitor)
    var total: Double
    var pressure: Double         // 0...100
    var swapUsed: Double         // bytes
}

/// CPU usage from per-core tick deltas, plus GPU usage, memory and thermal state.
final class SystemStatsReader {
    private var previousTicks: [[UInt32]] = []
    /// On Apple Silicon the efficiency cores are numbered first (perflevel1).
    private let efficiencyCount = SystemStatsReader.sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    func readUsage() -> UsageReading? {
        guard let ticks = Self.cpuTicks() else { return nil }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return nil }

        var perCore: [Double] = []
        for (now, before) in zip(ticks, previousTicks) {
            let d = zip(now, before).map { Double($0 &- $1) }
            let busy = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            let total = busy + d[Int(CPU_STATE_IDLE)]
            perCore.append(total > 0 ? busy / total * 100 : 0)
        }
        func mean(_ xs: ArraySlice<Double>) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        let split = min(efficiencyCount, perCore.count)
        return UsageReading(cpu: mean(perCore[...]),
                            performanceCores: mean(perCore[split...]),
                            efficiencyCores: mean(perCore[..<split]),
                            gpu: Self.gpuUtilization())
    }

    func readMemory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let level = Self.sysctlInt("kern.memorystatus_level") ?? 100
        return MemoryReading(used: used, total: Double(ProcessInfo.processInfo.physicalMemory),
                             pressure: Double(100 - level), swapUsed: Double(swap.xsu_used))
    }

    private static func cpuTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let util = stats["Device Utilization %"] as? NSNumber {
                return util.doubleValue
            }
        }
        return nil
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
