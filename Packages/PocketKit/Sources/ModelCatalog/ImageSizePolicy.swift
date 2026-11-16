import Foundation

/// How large an image the vision model is given. The photo is stored at full size; this
/// is applied where it is handed to the model, so it can change without touching saved chats.
public enum ImageSizePolicy {
    /// Longest side, in pixels, for devices with at most `smallDeviceMemoryBytes` of RAM.
    public static let smallDeviceMaxDimension = 1024
    /// Longest side on devices with more memory.
    public static let largeDeviceMaxDimension = 1536
    /// 8 GB, the iPhone 15 Pro and most current iPads.
    public static let smallDeviceMemoryBytes: Int64 = 8 << 30

    public static func maxDimension(for device: DeviceProfile) -> Int {
        device.physicalMemoryBytes <= smallDeviceMemoryBytes ? smallDeviceMaxDimension : largeDeviceMaxDimension
    }
}
