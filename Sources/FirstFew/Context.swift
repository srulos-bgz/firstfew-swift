import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device context, attached to every event. Everything here is collected without
/// any permission prompt — no IDFA, no IDFV, no ATT. The region comes from the
/// device's locale settings (no IP geolocation).
enum Context {
    /// Hardware model identifier, e.g. "iPhone17,2" ("arm64"/"x86_64" on simulator).
    static let deviceModel: String = {
        var sys = utsname()
        uname(&sys)
        return Mirror(reflecting: sys.machine).children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 {
                acc.append(Character(UnicodeScalar(UInt8(bitPattern: v))))
            }
        }
    }()

    static var osVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// "2.4.1 (87)" — short version plus build number.
    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        if short.isEmpty { return build }
        return build.isEmpty ? short : "\(short) (\(build))"
    }()

    /// The user's preferred language, including region variant (e.g. "zh-Hans-CN").
    static var language: String { Locale.preferredLanguages.first ?? "" }

    /// The device's region setting (e.g. "US").
    static var country: String {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.region?.identifier ?? ""
        }
        return Locale.current.regionCode ?? ""
    }

    /// Timezone offset in minutes — collected so per-user local-day reporting
    /// stays possible later.
    static var tzOffsetMin: Int { TimeZone.current.secondsFromGMT() / 60 }
}
