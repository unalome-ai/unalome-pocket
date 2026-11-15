import Foundation
#if os(iOS)
import os
#endif

/// The facts about this device that decide which models it can run.
/// A plain value, so tests can describe any device.
public struct DeviceProfile: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case phone, pad, mac
    }

    public var kind: Kind
    public var physicalMemoryBytes: Int64
    /// Memory this process may still allocate before the system stops it
    /// (`os_proc_available_memory` on iOS). `nil` where the OS does not report it (macOS).
    public var availableMemoryBytes: Int64?
    /// Free space for important data on the volume that holds models. `nil` if unknown.
    public var freeDiskBytes: Int64?
    /// `hw.machine` on iOS (e.g. `iPhone16,1`), `hw.model` on macOS (e.g. `Mac15,6`).
    public var machineIdentifier: String
    public var thermalState: ProcessInfo.ThermalState
    public var isLowPowerModeEnabled: Bool

    public init(
        kind: Kind,
        physicalMemoryBytes: Int64,
        availableMemoryBytes: Int64? = nil,
        freeDiskBytes: Int64? = nil,
        machineIdentifier: String = "test",
        thermalState: ProcessInfo.ThermalState = .nominal,
        isLowPowerModeEnabled: Bool = false
    ) {
        self.kind = kind
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.machineIdentifier = machineIdentifier
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// Memory a model may use. The OS-reported headroom when known; otherwise 60% of RAM,
    /// leaving the rest to the system and the app itself.
    public var memoryBudgetBytes: Int64 {
        availableMemoryBytes ?? physicalMemoryBytes * 6 / 10
    }

    /// Reads the current device. `storageDirectory` is where models are kept, for the disk check.
    public static func current(storageDirectory: URL) -> DeviceProfile {
        let processInfo = ProcessInfo.processInfo
        return DeviceProfile(
            kind: currentKind(),
            physicalMemoryBytes: Int64(clamping: processInfo.physicalMemory),
            availableMemoryBytes: availableMemory(),
            freeDiskBytes: freeDiskSpace(at: storageDirectory),
            machineIdentifier: machineIdentifier(),
            thermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }

    private static func currentKind() -> Kind {
        #if os(macOS)
        return .mac
        #else
        // `hw.machine` starts with "iPad" on iPads; the Simulator reports the host, so check its model too.
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineIdentifier()
        return model.hasPrefix("iPad") ? .pad : .phone
        #endif
    }

    private static func availableMemory() -> Int64? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int64(bytes) : nil
        #else
        return nil
        #endif
    }

    static func freeDiskSpace(at directory: URL) -> Int64? {
        // The volume may not have the models folder yet; ask about the nearest existing ancestor.
        var url = directory
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func machineIdentifier() -> String {
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Reads the device, but keeps the memory figures measured once, at launch.
///
/// `os_proc_available_memory` shrinks while a model is loaded, so reading it live would make
/// the loaded model push every other model towards "too large". The launch reading, taken
/// before any model loads, is the budget for the whole session. Disk, thermal state and
/// Low Power Mode are read fresh each time.
public final class DeviceProfileProvider: Sendable {
    /// The device as read at launch.
    public let atLaunch: DeviceProfile
    private let read: @Sendable () -> DeviceProfile

    public init(read: @escaping @Sendable () -> DeviceProfile) {
        self.read = read
        self.atLaunch = read()
    }

    public func current() -> DeviceProfile {
        var profile = read()
        profile.physicalMemoryBytes = atLaunch.physicalMemoryBytes
        profile.availableMemoryBytes = atLaunch.availableMemoryBytes
        return profile
    }
}
