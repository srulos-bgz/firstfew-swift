import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// FirstFew links — the app's own URL scheme, `ff<App Store id>`.
///
/// Registering the scheme in the app's Info.plist (URL Types) lets web pages and
/// other apps open this app with `ff<id>://…`; the host app passes every URL it is
/// opened with to `FirstFew.handle(_:)`, which claims the ones in this scheme.
///
/// A link can carry the device's FirstFew identity on to a next address:
/// ```
/// ff<id>://forward?forwardUrl=<target>&app_version&language
/// ```
/// opens `<target>` — an `https://` page in Safari or another app's URL scheme —
/// with `ff_id=<FirstFew user id>` appended to its query, followed by each device
/// value the link lists by name, under that name with an `ff_` prefix:
/// `ff_external_id`, `ff_app_version`, `ff_os_version`, `ff_device_model`,
/// `ff_language`, `ff_country`. The link only says which values to take; the keys
/// are fixed, and the prefix keeps them apart from the target's own parameters.
/// A link without `forwardUrl` just opens the app.
///
/// Anyone can craft a link in the app's scheme (this SDK is open source), so a
/// target is only opened when the product's allowlist in the FirstFew console
/// (product settings ▸ manage) permits it. The list lives on the server only: the
/// SDK asks `POST /api/ingest/link-check` with the target's scheme and host right
/// before opening, and does nothing when the answer cannot be fetched (offline).
///
/// Every claimed link is reported as the reserved event `link_open`, with the
/// target's scheme and host (`to`) when it forwards, `blocked: true` when the
/// allowlist refused it, and `offline: true` when the check could not be made.
struct Link {
    static let forwardParam = "forwardUrl"
    static let eventID = "link_open"
    /// Every value lands on the target under `ff_<name>`.
    static let keyPrefix = "ff_"
    private static let idParam = "id"

    let url: URL
    /// The `forwardUrl` target as given, nil when the link only opens the app.
    let forwardTarget: String?
    /// The device values the link asks for, by name, in link order (names the
    /// SDK does not know are dropped; `id` is always sent and never listed here).
    let requested: [String]

    /// Does `url` use a FirstFew scheme (`ff` + App Store id)?
    static func isFirstFewLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme.count > 2, scheme.hasPrefix("ff") else { return false }
        return scheme.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
    }

    init?(url: URL) {
        guard Self.isFirstFewLink(url) else { return nil }
        self.url = url
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        forwardTarget = items.first { $0.name == Self.forwardParam }?.value.flatMap { $0.isEmpty ? nil : $0 }
        var seen: Set<String> = [Self.idParam]
        requested = items.compactMap { item in
            let name = item.name.lowercased()
            guard name != Self.forwardParam, Fields.names.contains(name), seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// The device values a link can take, each sent under its own fixed name.
    struct Fields {
        static let names: Set<String> = ["id", "external_id", "app_version", "os_version", "device_model", "language", "country"]

        var id: String
        var externalID: String?
        var appVersion = Context.appVersion
        var osVersion = Context.osVersion
        var deviceModel = Context.deviceModel
        var language = Context.language
        var country = Context.country

        fileprivate func value(named name: String) -> String? {
            switch name {
            case "id": return id
            case "external_id": return externalID ?? ""
            case "app_version": return appVersion
            case "os_version": return osVersion
            case "device_model": return deviceModel
            case "language": return language
            case "country": return country
            default: return nil
            }
        }
    }

    /// The address to open: the target with `id` and the requested device values
    /// appended to its query. Nil when the link does not forward, the target does
    /// not parse, or it points back at this very scheme (a loop).
    func target(_ fields: Fields) -> URL? {
        guard let forwardTarget, var comps = URLComponents(string: forwardTarget),
              let scheme = comps.scheme, !scheme.isEmpty,
              scheme.lowercased() != url.scheme?.lowercased() else { return nil }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: Self.keyPrefix + Self.idParam, value: fields.id))
        for name in requested {
            items.append(URLQueryItem(name: Self.keyPrefix + name, value: fields.value(named: name)))
        }
        comps.queryItems = items
        return comps.url
    }

    /// `to` for the `link_open` event: the target's scheme and host, never its
    /// query (the target's own query may be anything the link author put there).
    static func destination(_ target: URL) -> String? {
        guard let scheme = target.scheme else { return nil }
        let host = target.host ?? ""
        return host.isEmpty ? "\(scheme)://" : "\(scheme)://\(host)"
    }

    /// Properties of the `link_open` event. `allowed` nil = the check could not
    /// be made (offline), false = the allowlist refused the target.
    func eventProperties(_ target: URL?, allowed: Bool? = true) -> [String: Any]? {
        guard let target, let to = Self.destination(target) else { return nil }
        var props: [String: Any] = ["to": to]
        switch allowed {
        case .some(false): props["blocked"] = true
        case .none: props["offline"] = true
        case .some(true): break
        }
        return props
    }

    /// How long a link waits for the allowlist answer before it is dropped. A
    /// link that cold-starts a freshly installed app lands on the first-launch
    /// network-permission prompt (mainland-China devices): every request fails
    /// until the user allows, so the check retries with short backoff — the
    /// first retry after the tap succeeds and the forward happens while the user
    /// is still looking at the app. Past the window, or once the app has gone to
    /// the background, the link is dropped: forwarding later would yank the user
    /// into Safari out of nowhere.
    static let checkWindow: TimeInterval = 60
    private static let checkDelays: [TimeInterval] = [1, 2, 4, 8]

    /// Ask the server whether `target` is on the product's allowlist. Completes
    /// with nil when no answer could be obtained within `checkWindow` — and the
    /// caller then does not forward.
    static func check(_ target: URL, token: String, baseURL: URL,
                      completion: @escaping (Bool?) -> Void) {
        guard let to = destination(target) else {
            completion(false)
            return
        }
        attemptCheck(to: to, token: token, baseURL: baseURL,
                     deadline: Date().addingTimeInterval(checkWindow), retry: 0, completion: completion)
    }

    private static func attemptCheck(to: String, token: String, baseURL: URL, deadline: Date, retry: Int,
                                     completion: @escaping (Bool?) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/ingest/link-check"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["to": to])
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let allowed = obj["allowed"] as? Bool {
                completion(allowed)
                return
            }
            // 4xx is a real answer (bad token, bad body): no point asking again.
            // Anything else — no network yet, 5xx, a timeout — is retried while
            // the window is open and the app is still in front of the user.
            let delay = checkDelays[min(retry, checkDelays.count - 1)]
            guard !(400..<500).contains(status), Date().addingTimeInterval(delay) < deadline, inForeground() else {
                completion(nil)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                attemptCheck(to: to, token: token, baseURL: baseURL, deadline: deadline, retry: retry + 1,
                             completion: completion)
            }
        }.resume()
    }

    /// False once the app has gone to the background (the user left — a forward
    /// must not fire when they come back). True wherever the state is unknown.
    private static func inForeground() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        var state = UIApplication.State.active
        if Thread.isMainThread {
            state = application()?.applicationState ?? .active
        } else {
            DispatchQueue.main.sync { state = application()?.applicationState ?? .active }
        }
        return state != .background
        #else
        return true
        #endif
    }

    /// Open `target` from the main thread, once the app is active — a link that
    /// cold-starts the app arrives before activation, when `open` is ignored.
    static func open(_ target: URL) {
        #if canImport(UIKit) && !os(watchOS)
        DispatchQueue.main.async {
            guard let app = application() else { return }
            if app.applicationState == .active {
                app.open(target, options: [:], completionHandler: nil)
                return
            }
            final class Observer { var token: NSObjectProtocol? }
            let observer = Observer()
            observer.token = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                guard let token = observer.token else { return }
                NotificationCenter.default.removeObserver(token)
                observer.token = nil
                app.open(target, options: [:], completionHandler: nil)
            }
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// `UIApplication.shared`, looked up at run time: the compile-time reference is
    /// unavailable to code that may also be linked into an app extension.
    private static func application() -> UIApplication? {
        let shared = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: shared) else { return nil }
        return UIApplication.perform(shared)?.takeUnretainedValue() as? UIApplication
    }
    #endif
}
