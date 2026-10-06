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
/// OS version / app version / language / region context, ASA attribution reporting,
/// and (iOS 15+) StoreKit transaction reporting — the device's own purchase history
/// is sent so purchases made outside the app (offer codes redeemed on the App Store,
/// family sharing, restores) are still tied to this user.
/// Add `push: true` to `configure` and the device's remote-push token is collected
/// as well, with no further code.
/// Report business events with `FirstFew.track("event_id")`.
/// `FirstFew.sales()` tells a purchase screen about the temporary sales set up in the
/// console for the device's App Store region: the regular price and the end date
/// StoreKit does not provide. It needs no products, so it runs alongside loading them.
/// Pass the URLs the app is opened with to `FirstFew.handle(_:)` and links in the
/// app's FirstFew scheme (`ff<App Store id>://…`) are handled: they can carry the
/// device's FirstFew id on to a web page or another app.
///
/// The token is write-only (it can submit data, never read anything back). All
/// reporting is fire-and-forget with a durable on-disk queue and backoff retries —
/// it never blocks or breaks the host app.
public final class FirstFew {
    /// SDK version, sent with every event as `sdk: "ios/x.y.z"` — lets the server
    /// tell SDK traffic from raw-API traffic and track version adoption.
    public static let sdkVersion = "0.5.0"

    private static let shared = FirstFew()
    private let work = DispatchQueue(label: "com.firstfew.sdk")
    private var queue: EventQueue?
    private var identity: Identity?
    private var configured = false
    private var pendingLink: Link?
    private var ingest: (token: String, baseURL: URL)?

    private init() {}

    /// Call once at app startup. `token` comes from FirstFew product settings
    /// (data services); `baseURL` is the ingest host.
    ///
    /// Pass `push: true` to collect the device's remote-push (APNs) token with no
    /// further code: the SDK registers the app for remote notifications and picks
    /// the token up from the app delegate, where an existing handler keeps working.
    /// The app needs the Push Notifications capability. No permission prompt is
    /// shown — asking the user to allow notifications stays with the app. Off by
    /// default; an app that prefers the SDK not to touch its delegate can forward
    /// the token with `setPushToken(_:)` instead.
    public static func configure(token: String, baseURL: URL, push: Bool = false) {
        #if canImport(UIKit) && !os(watchOS)
        if push { PushRegistration.enable() }
        #endif
        shared.work.async { shared.start(token: token, baseURL: baseURL) }
    }

    /// Report the APNs device token yourself — the alternative to `push: true`:
    /// ```swift
    /// func application(_ application: UIApplication,
    ///                  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    ///     FirstFew.setPushToken(deviceToken)
    /// }
    /// ```
    /// It may be called before `configure`; the token is reported once the SDK
    /// starts, and again whenever it or the notification permission changes.
    public static func setPushToken(_ deviceToken: Data) {
        PushTokenReporter.update(deviceToken: deviceToken)
    }

    /// Handle a URL the app was opened with. Pass every URL; the SDK claims the
    /// ones in the app's FirstFew scheme — `ff<App Store id>://…`, registered under
    /// URL Types in Info.plist — and returns `true` for those, `false` for any
    /// other URL (handle those as usual).
    /// ```swift
    /// // UIKit (app delegate)
    /// func application(_ app: UIApplication, open url: URL,
    ///                  options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    ///     if FirstFew.handle(url) { return true }
    ///     …
    /// }
    /// // SwiftUI
    /// .onOpenURL { url in FirstFew.handle(url) }
    /// ```
    /// A link `ff<id>://forward?forwardUrl=<target>&app_version&language` opens
    /// `<target>` — an https page or another app's URL scheme — with
    /// `ff_id=<FirstFew user id>` and the device values the link names appended
    /// to its query under fixed `ff_` keys, provided the target is on the product's
    /// allowlist in the FirstFew console (checked with the server right before
    /// opening; nothing happens offline); see `Link`. A link without
    /// `forwardUrl` just opens the app. Every handled link is reported as the
    /// reserved event `link_open`. May be called before `configure`; the link is
    /// then handled once the SDK starts.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard let link = Link(url: url) else { return false }
        shared.work.async { shared.open(link) }
        return true
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

    /// The stable FirstFew user id (a lowercase UUID string, kept in the Keychain).
    /// This is the same id sent with every event and with attribution reporting.
    /// `nil` only before the very first `configure` call of the app's first launch.
    public static var userId: String? {
        Identity.existingUserID()
    }

    /// The user id as a `UUID`, ready to be passed as StoreKit's `appAccountToken`
    /// when starting a purchase:
    /// ```swift
    /// let result = try await product.purchase(options: [
    ///     .appAccountToken(FirstFew.appAccountToken ?? UUID())
    /// ])
    /// ```
    /// App Store Server Notifications then carry this token on every transaction —
    /// first purchase, renewals, refunds — which lets FirstFew tie revenue to the
    /// user and, through Search Ads attribution, to the exact keyword that
    /// acquired them (per-keyword ROAS). Strongly recommended for any paid app.
    public static var appAccountToken: UUID? {
        Identity.existingUserID().flatMap(UUID.init(uuidString:))
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
        ingest = (token, baseURL)
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
        // StoreKit transaction history (iOS 15+): ties purchases without an
        // appAccountToken (offer codes, family sharing, restores) to this user.
        TransactionReporter.start(userID: identity.userID, token: token, baseURL: baseURL)
        // Remote-push token: reports whatever `push: true` or setPushToken delivers.
        PushTokenReporter.start(userID: identity.userID, token: token, baseURL: baseURL)
        // Temporary sales of the device's App Store region (FirstFew.sales()).
        SaleStore.start(token: token, baseURL: baseURL)
        // A link handed to `handle` before `configure` waited for the identity.
        if let link = pendingLink {
            pendingLink = nil
            open(link)
        }
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

    private static let externalIdKey = "com.firstfew.sdk.external_id"

    /// Bind the app's own account id to this FirstFew user ("identify" / aliasing).
    /// Call it after login (and again whenever the logged-in account changes):
    /// ```swift
    /// FirstFew.identify("your-account-id")
    /// ```
    /// Every event reported afterwards carries it as `external_id`, so the FirstFew
    /// console can be searched by your own user ids, multiple devices of the same
    /// account are grouped, and server-side reporting can address the user by the
    /// id your backend already knows. Pass `nil` on logout to stop attaching it
    /// (the binding already recorded server-side is kept).
    public static func identify(_ externalId: String?) {
        let trimmed = externalId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, trimmed.count <= 128 {
            let changed = UserDefaults.standard.string(forKey: externalIdKey) != trimmed
            UserDefaults.standard.set(trimmed, forKey: externalIdKey)
            // Deliver the binding right away via the reserved `identify` event —
            // otherwise it would wait for the next business event, which can be
            // long after a login. Durable queue + retries apply as usual.
            if changed {
                shared.work.async { shared.enqueue("identify", value: nil, currency: nil, properties: nil) }
            }
        } else {
            UserDefaults.standard.removeObject(forKey: externalIdKey)
        }
    }

    /// Report a FirstFew link and open its forward target once the server has
    /// confirmed the target is allowed. Runs on `work`; the identity is needed
    /// for `id`, so a link arriving before `configure` waits (the identity must
    /// not be created here — that would hide a reinstall).
    private func open(_ link: Link) {
        guard let identity, let ingest else {
            pendingLink = link
            return
        }
        let fields = Link.Fields(id: identity.userID,
                                 externalID: UserDefaults.standard.string(forKey: Self.externalIdKey))
        guard let target = link.target(fields) else {
            enqueue(Link.eventID, value: nil, currency: nil, properties: nil)
            return
        }
        Link.check(target, token: ingest.token, baseURL: ingest.baseURL) { [weak self] allowed in
            guard let self else { return }
            self.work.async {
                self.enqueue(Link.eventID, value: nil, currency: nil,
                             properties: link.eventProperties(target, allowed: allowed))
            }
            if allowed == true { Link.open(target) }
        }
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
        if let ext = UserDefaults.standard.string(forKey: Self.externalIdKey), !ext.isEmpty {
            event["external_id"] = ext
        }
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
