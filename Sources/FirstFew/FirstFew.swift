import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// FirstFew analytics SDK.
///
/// Initialize once at launch:
/// ```swift
/// FirstFew.configure(token: "<ingest token>", baseURL: URL(string: "https://…")!)
/// ```
/// After that, everything below happens automatically: `app_launch` on every launch
/// and return to foreground, reinstall detection (`app_reinstall`), device model /
/// OS version / app version / language / region context, and ASA attribution reporting.
/// Report business events with `FirstFew.track("event_id")`.
///
/// The token is write-only (it can submit data, never read anything back). All
/// reporting is fire-and-forget with a durable on-disk queue and backoff retries —
/// it never blocks or breaks the host app.
public final class FirstFew {
    /// SDK version, sent with every event as `sdk: "ios/x.y.z"` — lets the server
    /// tell SDK traffic from raw-API traffic and track version adoption.
    public static let sdkVersion = "0.1.0"

    private static let shared = FirstFew()
    private let work = DispatchQueue(label: "com.firstfew.sdk")
    private var queue: EventQueue?
    private var identity: Identity?
    private var configured = false

    private init() {}

    /// Call once at app startup. `token` comes from FirstFew product settings
    /// (data services); `baseURL` is the ingest host.
    public static func configure(token: String, baseURL: URL) {
        shared.work.async { shared.start(token: token, baseURL: baseURL) }
    }

    /// Receive the Apple Search Ads attribution result. The completion runs on the
    /// main queue as soon as the final answer is available — immediately when it is
    /// already cached (it persists across launches), otherwise when reporting
    /// completes in this session. The dictionary always contains `attribution`
    /// (Bool: did this user come from a Search Ads campaign); extra fields such as
    /// `campaign_id` / `keyword_id` appear when enabled in the FirstFew console.
    /// If the answer cannot be fetched this session, the callback fires on a later
    /// launch's call instead — never block product flows waiting for it.
    public static func attribution(_ completion: @escaping ([String: Any]) -> Void) {
        AttributionReporter.onResult(completion)
    }

    /// Report a business event. Use the snake_case id defined in FirstFew event
    /// management. Composed events are derived server-side — never send them.
    /// Pass `value`/`currency` only for events with payment semantics.
    public static func track(_ eventId: String,
                             value: Double? = nil,
                             currency: String? = nil,
                             properties: [String: Any]? = nil) {
        shared.work.async { shared.enqueue(eventId, value: value, currency: currency, properties: properties) }
    }

    private func start(token: String, baseURL: URL) {
        guard !configured else { return }
        configured = true
        let identity = Identity()
        self.identity = identity
        self.queue = EventQueue(token: token, baseURL: baseURL)
        // Cold start counts as one app_launch; a reinstall (Keychain id present but
        // install marker gone) additionally reports app_reinstall.
        enqueue("app_launch", value: nil, currency: nil, properties: nil)
        if identity.isReinstall {
            enqueue("app_reinstall", value: nil, currency: nil, properties: nil)
        }
        AttributionReporter.reportIfNeeded(userID: identity.userID, token: token, baseURL: baseURL)
        #if canImport(UIKit)
        // Returning to the foreground counts as a launch too (active users = distinct
        // users with an app_launch that day).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.work.async { self.enqueue("app_launch", value: nil, currency: nil, properties: nil) }
        }
        #endif
    }

    private func enqueue(_ eventId: String, value: Double?, currency: String?, properties: [String: Any]?) {
        guard let identity, let queue else { return }
        var event: [String: Any] = [
            "user_id": identity.userID,
            "event_id": eventId,
            "event_time": Self.iso8601.string(from: Date()),
            "platform": "ios",
            "device_model": Context.deviceModel,
            "os_version": Context.osVersion,
            "app_version": Context.appVersion,
            "language": Context.language,
            "tz_offset_min": Context.tzOffsetMin,
            "sdk": "ios/\(Self.sdkVersion)",
        ]
        if !Context.country.isEmpty { event["country"] = Context.country }
        if let value { event["value"] = value }
        if let currency { event["currency"] = currency }
        if let properties, JSONSerialization.isValidJSONObject(properties) {
            event["properties"] = properties
        }
        queue.add(event)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
