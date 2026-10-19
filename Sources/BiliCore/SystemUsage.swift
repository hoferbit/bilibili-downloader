import Foundation
import IOKit

public struct SystemUsage: Sendable {
    /// 整机 CPU 时间占比，0...100，所有核心合计归一化。
    public let cpu: Double?
    /// 整机 GPU 驱动报告的 Device Utilization，无法读取时为 nil。
    public let gpu: Double?
}

/// 不启动外部进程、不需要管理员权限。Actor 在后台采样，避免阻塞 SwiftUI。
public actor SystemUsageProbe {
    private var previous: [UInt32]?
    public init() {}

    public func sample() -> SystemUsage {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        var cpu: Double?
        if status == KERN_SUCCESS {
            let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
            if let previous {
                let delta = zip(ticks, previous).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { cpu = min(100, max(0, (total - delta[Int(CPU_STATE_IDLE)]) / total * 100)) }
            }
            previous = ticks
        }
        return SystemUsage(cpu: cpu, gpu: gpuUsage())
    }

    private func gpuUsage() -> Double? {
        var values: [Double] = []
        for name in ["AGXAccelerator", "IOAccelerator"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                      let dict = property.takeRetainedValue() as? [String: Any],
                      let value = dict["Device Utilization %"] as? NSNumber else { continue }
                values.append(min(100, max(0, value.doubleValue)))
            }
            if !values.isEmpty { break }
        }
        return values.max()
    }
}
