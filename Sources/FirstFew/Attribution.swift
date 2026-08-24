import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Automatic Apple Search Ads attribution reporting — plus result delivery.
///
/// On first launch the SDK gets an AdServices attribution token and reports it to
/// FirstFew (whose server asks Apple on the developer's behalf). A 200 response is
/// the final answer: it is cached locally and never requested again.
///
/// Retry model (this matters on first launch — e.g. mainland-China devices show a
/// network-permission dialog and ALL requests fail until the user allows):
/// - Network failure / 429 / 5xx — including `AAAttribution.attributionToken()`
///   itself failing, which happens without connectivity — retries in-session with
///   backoff (5s doubling up to 60s, then every 60s). It never gives up while the
///   app is running, so the report goes out as soon as the network becomes usable.
/// - 202 (Apple's data not ready yet — normal right after install): polls 5s → 15s
///   → 30s, then leaves it to the server's background requery and the next launch.
/// - 400/401 (invalid token): stops; a fresh token is fetched on the next launch.
///
/// Fire-and-forget — never affects the host app. The host receives the result via
/// `FirstFew.attribution { ... }`, which fires as soon as the final answer is
/// available (immediately when cached).
enum AttributionReporter {
    private static let doneKey = "com.firstfew.sdk.attribution_reported"
    private static let resultKey = "com.firstfew.sdk.attribution_result"
    private static let pendingPollDelays: [TimeInterval] = [5, 15, 30]
    private static let maxFailureDelay: TimeInterval = 60
    private static let lock = NSLock()
    private static var callbacks: [([String: Any]) -> Void] = []

    /// The cached final answer, or nil while unresolved. Contains "attribution"
    /// (Bool) plus whatever extra fields are enabled in the FirstFew console.
    static func cachedResult() -> [String: Any]? {
        guard let data = UserDefaults.standard.data(forKey: resultKey),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }

    /// Register a result callback (invoked on the main queue). Fires immediately
    /// when the answer is already cached; otherwise when reporting completes in
    /// this session. Unresolved callbacks are not persisted — calling again on a
    /// later launch returns the cached answer.
    static func onResult(_ completion: @escaping ([String: Any]) -> Void) {
        if let r = cachedResult() {
            DispatchQueue.main.async { completion(r) }
            return
        }
        lock.lock()
        callbacks.append(completion)
        lock.unlock()
    }

    static func reportIfNeeded(userID: String, token: String, baseURL: URL) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        attempt(userID: userID, token: token, baseURL: baseURL, pendingPolls: 0, failureDelay: 5)
    }

    private static func attempt(userID: String, token: String, baseURL: URL,
                                pendingPolls: Int, failureDelay: TimeInterval) {
        #if canImport(AdServices)
        guard #available(iOS 14.3, macOS 11.1, *) else { return }
        DispatchQueue.global(qos: .utility).async {
            // The attribution token is valid for 24h — fetch a fresh one per attempt.
            // Token generation itself needs connectivity and fails while e.g. the
            // network-permission dialog is unanswered — treat that as a retryable
            // failure, NOT a give-up.
            guard let attrToken = try? AAAttribution.attributionToken() else {
                retryAfterFailure(userID: userID, token: token, baseURL: baseURL,
                                  pendingPolls: pendingPolls, failureDelay: failureDelay)
                return
            }
            var req = URLRequest(url: baseURL.appendingPathComponent("api/ingest/attribution"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": userID, "token": attrToken])
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    guard let data,
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                    if let stored = try? JSONSerialization.data(withJSONObject: obj) {
                        UserDefaults.standard.set(stored, forKey: resultKey)
                    }
                    UserDefaults.standard.set(true, forKey: doneKey)
                    deliver(obj)
                case 202:
                    // Apple not ready yet: short in-session polling, then leave it
                    // to the server's background requery and the next launch.
                    guard pendingPolls < pendingPollDelays.count else { return }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pendingPollDelays[pendingPolls]) {
                        attempt(userID: userID, token: token, baseURL: baseURL,
                                pendingPolls: pendingPolls + 1, failureDelay: 5)
                    }
                case 400, 401:
                    break // invalid token: stop; a fresh token is fetched next launch
                default:
                    // Network failure (status 0) / 429 / 5xx: keep retrying in-session.
                    retryAfterFailure(userID: userID, token: token, baseURL: baseURL,
                                      pendingPolls: pendingPolls, failureDelay: failureDelay)
                }
            }.resume()
        }
        #endif
    }

    private static func retryAfterFailure(userID: String, token: String, baseURL: URL,
                                          pendingPolls: Int, failureDelay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + failureDelay) {
            attempt(userID: userID, token: token, baseURL: baseURL,
                    pendingPolls: pendingPolls, failureDelay: min(failureDelay * 2, maxFailureDelay))
        }
    }

    private static func deliver(_ result: [String: Any]) {
        lock.lock()
        let cbs = callbacks
        callbacks = []
        lock.unlock()
        for cb in cbs {
            DispatchQueue.main.async { cb(result) }
        }
    }
}
