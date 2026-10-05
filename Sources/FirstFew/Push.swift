import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Remote-push device token reporting.
///
/// The APNs device token is the address a remote notification is sent to. It reaches
/// this reporter in one of two ways: `FirstFew.configure(..., push: true)` makes the
/// SDK register with APNs and pick the token up by itself (`PushRegistration`), or
/// the host app forwards it with `FirstFew.setPushToken(_:)`.
///
/// A token alone is not enough to deliver a notification later, so three facts
/// travel with it: the APNs environment the build registers with (sandbox and
/// production tokens are not interchangeable), the bundle id (the APNs topic), and
/// the notification authorization status — APNs accepts a push for a user who has
/// turned notifications off, so only the device knows whether it will be shown.
///
/// The token is kept in UserDefaults so that a change of authorization (the user
/// answering the permission prompt, or switching notifications off in Settings) is
/// reported the next time the app becomes active, even when the host app does not
/// register again in that session. Nothing is sent while token, environment and
/// status are unchanged since the last successful report (fingerprint in
/// UserDefaults). Fire-and-forget with in-session backoff; never blocks the host app.
enum PushTokenReporter {
    private static let tokenKey = "com.firstfew.sdk.push_token"
    private static let fingerprintKey = "com.firstfew.sdk.push_token_fingerprint"
    private static let maxAttempts = 5
    private static let work = DispatchQueue(label: "com.firstfew.sdk.push")

    // Everything below is touched on `work` only.
    private static var destination: (userID: String, token: String, baseURL: URL)?
    private static var inFlight = false
    private static var rerunRequested = false

    static func start(userID: String, token: String, baseURL: URL) {
        work.async {
            guard destination == nil else { return }
            destination = (userID, token, baseURL)
            schedule()
            #if canImport(UIKit) && !os(watchOS)
            // The permission prompt and a trip to Settings both end with the app
            // becoming active again — the moment to look at the status once more.
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { _ in work.async { schedule() } }
            #endif
        }
    }

    /// A device token handed out by the system. Safe to call before `start`: the
    /// token waits in UserDefaults and is reported once the SDK is configured.
    static func update(deviceToken: Data) {
        guard !deviceToken.isEmpty else { return }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        work.async {
            UserDefaults.standard.set(hex, forKey: tokenKey)
            schedule()
        }
    }

    /// One report at a time; a request arriving mid-flight runs once more after.
    private static func schedule() {
        guard #available(iOS 14, macOS 10.15, tvOS 14, watchOS 7, *) else { return }
        guard destination != nil, UserDefaults.standard.string(forKey: tokenKey) != nil else { return }
        if inFlight {
            rerunRequested = true
            return
        }
        inFlight = true
        attempt(0)
    }

    private static func finish() {
        inFlight = false
        if rerunRequested {
            rerunRequested = false
            schedule()
        }
    }

    @available(iOS 14, macOS 10.15, tvOS 14, watchOS 7, *)
    private static func attempt(_ number: Int) {
        // Token and status are read again on every attempt, so a retry always
        // sends the current state rather than the one that failed.
        guard let destination, let hex = UserDefaults.standard.string(forKey: tokenKey) else {
            finish()
            return
        }
        authorizationStatus { status in
            work.async {
                var body: [String: Any] = [
                    "user_id": destination.userID,
                    "token": hex,
                    "environment": PushEnvironment.current,
                    "sdk": "ios/\(FirstFew.sdkVersion)",
                ]
                if let bundleID = Bundle.main.bundleIdentifier { body["bundle_id"] = bundleID }
                if !status.isEmpty { body["authorization_status"] = status }
                let endpoint = destination.baseURL.appendingPathComponent("api/ingest/push-token")
                guard let payload = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                    finish()
                    return
                }
                // The destination is part of the fingerprint: pointing the SDK at
                // another product or host reports the token there too.
                let fingerprint = SHA256.hash(data: Data("\(endpoint.absoluteString)|\(destination.token)|".utf8) + payload)
                    .map { String(format: "%02x", $0) }.joined()
                if UserDefaults.standard.string(forKey: fingerprintKey) == fingerprint {
                    finish()
                    return
                }
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("Bearer \(destination.token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload
                URLSession.shared.dataTask(with: req) { _, resp, _ in
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    work.async {
                        switch code {
                        case 200:
                            UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
                            finish()
                        case 400, 401, 402, 413:
                            finish() // unrecoverable client error: try again when the app next becomes active
                        default:
                            // Network failure / 429 / 5xx: back off in-session (5, 10, 20, 40s),
                            // then leave it to the next launch or activation.
                            guard number + 1 < maxAttempts else {
                                finish()
                                return
                            }
                            let delay = min(5 * pow(2, Double(number)), 40)
                            work.asyncAfter(deadline: .now() + delay) { attempt(number + 1) }
                        }
                    }
                }.resume()
            }
        }
    }

    /// The user's notification permission, read without prompting. Empty when it
    /// cannot be read.
    @available(iOS 14, macOS 10.15, tvOS 14, watchOS 7, *)
    private static func authorizationStatus(_ completion: @escaping (String) -> Void) {
        #if canImport(UserNotifications)
        // UNUserNotificationCenter.current() raises in a process that is not an app
        // or extension bundle (command-line tools, package test runners).
        guard ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension) else {
            completion("")
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined: completion("not_determined")
            case .denied: completion("denied")
            case .authorized: completion("authorized")
            case .provisional: completion("provisional")
            #if os(iOS)
            case .ephemeral: completion("ephemeral")
            #endif
            @unknown default: completion("")
            }
        }
        #else
        completion("")
        #endif
    }
}

/// The APNs environment this build registers with. A device token is only valid in
/// the environment that issued it, so the environment is reported alongside it.
enum PushEnvironment {
    static let current: String = {
        #if targetEnvironment(simulator)
        return "sandbox" // the Simulator always registers with the APNs sandbox
        #else
        // Builds installed from Xcode, ad hoc and enterprise builds carry their
        // provisioning profile, whose aps-environment entitlement says which APNs
        // they use. App Store and TestFlight builds carry none and use production.
        let candidates = [
            Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"), // Mac Catalyst
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let environment = apsEnvironment(inProfile: data) {
                return environment == "development" ? "sandbox" : "production"
            }
        }
        return "production"
        #endif
    }()

    /// The aps-environment entitlement of a provisioning profile ("development" or
    /// "production"), or nil when the profile has none. A profile is a signed
    /// envelope around an XML property list, which sits in it as plain text.
    static func apsEnvironment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any] else { return nil }
        return (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Zero-code token pickup for `FirstFew.configure(..., push: true)`.
///
/// Registers the app with APNs and watches the app delegate's
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` — the only
/// place the system hands the token out — so the host app does not have to forward
/// it. Registering shows no permission prompt. It needs the Push Notifications
/// capability: without it the system rejects the registration and nothing is
/// collected.
///
/// Watching means changing a method on an object the host app owns, the one thing
/// in this SDK that could affect the app, so it is kept as narrow as possible:
/// - only that one delegate method is involved, and whatever implemented it before
///   — the app's own code, a superclass, another SDK — still runs, with the same
///   arguments, right after the token has been noted;
/// - in a SwiftUI app the delegate that counts is the one behind
///   `@UIApplicationDelegateAdaptor`, which SwiftUI's own app delegate forwards to;
///   that forwarding is followed, never cut off;
/// - a delegate that answers the method in a way that cannot be seen through is
///   left alone, and nothing is registered. Forward the token with
///   `FirstFew.setPushToken(_:)` in that case.
enum PushRegistration {
    // Main thread only.
    private static var enabled = false
    private static var activated = false
    private static var observers: [NSObjectProtocol] = []

    static func enable() {
        // App extensions have no UIApplication and must not register.
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        onMain {
            guard !enabled else { return }
            enabled = true
            // The delegate is only complete once launch has finished (SwiftUI creates
            // the adaptor's delegate during launch), so wait for that. A configure()
            // that runs after launch has missed the notification — becoming active
            // covers it, and so does the check below for an app that already is.
            observers = [UIApplication.didFinishLaunchingNotification, UIApplication.didBecomeActiveNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: nil) { _ in onMain(activate) }
            }
            if application()?.applicationState == .active { activate() }
        }
    }

    private static func activate() {
        guard !activated, let app = application() else { return }
        activated = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let delegate = app.delegate as? NSObject, watch(delegate) else { return }
        // The app may register on its own as well; a second call only makes the
        // system hand the same token out again.
        app.registerForRemoteNotifications()
    }

    /// Returns false when the delegate could not be watched safely.
    private static func watch(_ delegate: NSObject) -> Bool {
        let selector = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        typealias Implementation = @convention(c) (AnyObject, Selector, UIApplication, NSData) -> Void

        // Who handles the call: the delegate, or the object it forwards to.
        var handler = delegate
        var forwardedTo: NSObject?
        var hops = 0
        while hops < 4, class_getInstanceMethod(object_getClass(handler), selector) == nil,
              let next = handler.forwardingTarget(for: selector) as? NSObject, next !== handler {
            handler = next
            forwardedTo = next
            hops += 1
        }

        if let cls = object_getClass(handler), let method = class_getInstanceMethod(cls, selector) {
            // Someone implements it: note the token, then run what was there.
            let superclass: AnyClass? = class_getSuperclass(cls)
            var replaced: IMP?
            let block: @convention(block) (AnyObject, UIApplication, NSData) -> Void = { receiver, app, token in
                PushTokenReporter.update(deviceToken: token as Data)
                // An inherited implementation is looked up at call time, so a hook
                // another SDK puts on the superclass later still runs.
                let next = replaced ?? superclass.flatMap { class_getInstanceMethod($0, selector) }.map(method_getImplementation)
                if let next { unsafeBitCast(next, to: Implementation.self)(receiver, selector, app, token) }
            }
            let implementation = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            // An inherited method gets an override on this class only, leaving the
            // superclass and its other subclasses untouched; the class's own method
            // is replaced.
            if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
                replaced = method_setImplementation(method, implementation)
            }
            return true
        }

        // Nobody implements it. Add it to the delegate's class — unless the delegate
        // claims to answer it anyway, by means that adding a method would override.
        guard !delegate.responds(to: selector), let cls = object_getClass(delegate),
              let types = protocol_getMethodDescription(UIApplicationDelegate.self, selector, false, true).types else { return false }
        let block: @convention(block) (AnyObject, UIApplication, NSData) -> Void = { [weak forwardedTo] _, app, token in
            PushTokenReporter.update(deviceToken: token as Data)
            // The call would have been forwarded had this method not been added;
            // should that object gain an implementation later, it still gets it.
            (forwardedTo as? UIApplicationDelegate)?.application?(app, didRegisterForRemoteNotificationsWithDeviceToken: token as Data)
        }
        return class_addMethod(cls, selector, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), types)
            && delegate.responds(to: selector)
    }

    /// `UIApplication.shared`, looked up at run time: the compile-time reference is
    /// unavailable to code that may also be linked into an app extension.
    private static func application() -> UIApplication? {
        let shared = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: shared) else { return nil }
        return UIApplication.perform(shared)?.takeUnretainedValue() as? UIApplication
    }

    private static func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
#endif
