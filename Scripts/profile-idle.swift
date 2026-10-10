import Darwin
import Foundation

// Read-only process profiling. Usage: swift Scripts/profile-idle.swift PID [seconds]
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("Usage: profile-idle.swift PID [seconds]\n", stderr)
    exit(2)
}
let duration = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 300 : 300
guard duration >= 1, duration <= 3600 else { exit(2) }

func sample(_ pid: Int32) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
    }
    return status == 0 ? info : nil
}
guard let initial = sample(pid) else { fputs("Cannot read process metrics\n", stderr); exit(1) }
let start = ProcessInfo.processInfo.systemUptime
var maximumMemory = initial.ri_phys_footprint
var minimumMemory = initial.ri_phys_footprint
var last = initial
while ProcessInfo.processInfo.systemUptime - start < duration {
    Thread.sleep(forTimeInterval: min(10, duration - (ProcessInfo.processInfo.systemUptime - start)))
    guard let next = sample(pid) else { fputs("Process exited during measurement\n", stderr); exit(1) }
    last = next
    maximumMemory = max(maximumMemory, next.ri_phys_footprint)
    minimumMemory = min(minimumMemory, next.ri_phys_footprint)
}
let elapsed = ProcessInfo.processInfo.systemUptime - start
let cpu = Double((last.ri_user_time - initial.ri_user_time) + (last.ri_system_time - initial.ri_system_time)) / 1e9
let output: [String: Any] = [
    "pid": pid, "seconds": elapsed, "averageCPUPercent": cpu / elapsed * 100,
    "idleWakeupsPerSecond": Double(last.ri_pkg_idle_wkups - initial.ri_pkg_idle_wkups) / elapsed,
    "interruptWakeupsPerSecond": Double(last.ri_interrupt_wkups - initial.ri_interrupt_wkups) / elapsed,
    "footprintStartMiB": Double(initial.ri_phys_footprint) / 1048576,
    "footprintEndMiB": Double(last.ri_phys_footprint) / 1048576,
    "footprintMinMiB": Double(minimumMemory) / 1048576,
    "footprintMaxMiB": Double(maximumMemory) / 1048576,
    "diskReadBytes": last.ri_diskio_bytesread - initial.ri_diskio_bytesread,
    "diskWriteBytes": last.ri_diskio_byteswritten - initial.ri_diskio_byteswritten,
]
let encoded = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
