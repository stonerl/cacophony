import Foundation

public enum CacophonyHelperConstants {
    public static let machServiceName = "com.stonerl.Cacophony.Helper"
    public static let launchDaemonPlistName = "com.stonerl.Cacophony.Helper.plist"
    public static let driverName = "CacophonyAudio.driver"
    public static let halDirectoryPath = "/Library/Audio/Plug-Ins/HAL"
}

@objc public protocol CacophonyHelperProtocol {
    func installDriver(withReply reply: @escaping (Bool, String?) -> Void)
    func uninstallDriver(withReply reply: @escaping (Bool, String?) -> Void)
}
