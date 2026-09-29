import Foundation
import CryptoKit
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Automatic StoreKit transaction reporting (iOS 15+ / StoreKit 2).
///
/// Purchases made outside the app — offer-code redemptions on the App Store, family
/// sharing, purchases restored on a new device — never carry an `appAccountToken`,
/// so App Store Server Notifications alone cannot tell FirstFew which user they
/// belong to. This reporter reads the device's own transaction history
/// (`Transaction.all`, verified entries only), collapses it to one row per
/// `originalTransactionId`, and sends the list to FirstFew, which maps every
/// notification with the same original transaction id — first purchase, renewals,
/// refunds — to this user. The rows also stand on their own: an app that has not
/// connected server notifications still gets its orders in the FirstFew console.
///
/// Runs after `configure`, on every return to the foreground, and whenever StoreKit
/// delivers a new transaction (`Transaction.updates`). Nothing is sent when the
/// list has not changed since the last successful report (fingerprint in
/// UserDefaults). Fire-and-forget with in-session backoff; never blocks the host app.
enum TransactionReporter {
    private static let fingerprintKey = "com.firstfew.sdk.transactions_fingerprint"
    private static let maxRetries = 5
    private static let lock = NSLock()
    private static var started = false
    private static var inFlight = false
    private static var rerunRequested = false

    static func start(userID: String, token: String, baseURL: URL) {
        #if canImport(StoreKit)
        guard #available(iOS 15, macOS 12, tvOS 15, watchOS 8, *) else { return }
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        guard !already else { return }
        schedule(userID: userID, token: token, baseURL: baseURL)
        // New transactions while the app is running (a purchase in-app, or an offer
        // code redeemed on the App Store while the app is open) — report right away.
        Task.detached(priority: .utility) {
            for await _ in Transaction.updates {
                schedule(userID: userID, token: token, baseURL: baseURL)
            }
        }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in
            schedule(userID: userID, token: token, baseURL: baseURL)
        }
        #endif
        #endif
    }

    /// One collection at a time; a request arriving mid-flight runs once more after.
    private static func schedule(userID: String, token: String, baseURL: URL) {
        #if canImport(StoreKit)
        guard #available(iOS 15, macOS 12, tvOS 15, watchOS 8, *) else { return }
        lock.lock()
        if inFlight {
            rerunRequested = true
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        Task.detached(priority: .utility) {
            await collectAndReport(userID: userID, token: token, baseURL: baseURL)
            lock.lock()
            inFlight = false
            let again = rerunRequested
            rerunRequested = false
            lock.unlock()
            if again { schedule(userID: userID, token: token, baseURL: baseURL) }
        }
        #endif
    }

    #if canImport(StoreKit)
    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
    private static func collectAndReport(userID: String, token: String, baseURL: URL) async {
        // One row per original transaction: the newest transaction of a subscription
        // represents it (latest expiry / revocation), the first purchase date is kept
        // separately so FirstFew knows when the customer originally bought.
        var rows: [UInt64: [String: Any]] = [:]
        var newestID: [UInt64: UInt64] = [:]
        for await result in Transaction.all {
            guard case .verified(let t) = result else { continue }
            if let seen = newestID[t.originalID], seen >= t.id { continue }
            newestID[t.originalID] = t.id
            var row: [String: Any] = [
                "original_transaction_id": String(t.originalID),
                "transaction_id": String(t.id),
                "product_id": t.productID,
                "product_type": productType(t.productType),
                "purchased_at": iso8601.string(from: t.purchaseDate),
                "original_purchased_at": iso8601.string(from: t.originalPurchaseDate),
                "ownership": t.ownershipType == .familyShared ? "family_shared" : "purchased",
                "is_upgraded": t.isUpgraded,
            ]
            if let e = t.expirationDate { row["expires_at"] = iso8601.string(from: e) }
            if let r = t.revocationDate { row["revoked_at"] = iso8601.string(from: r) }
            if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
                switch t.environment {
                case .sandbox: row["environment"] = "Sandbox"
                case .xcode: row["environment"] = "Xcode"
                case .production: row["environment"] = "Production"
                default: row["environment"] = t.environment.rawValue
                }
            }
            rows[t.originalID] = row
        }
        let list = rows.keys.sorted().compactMap { rows[$0] }
        guard JSONSerialization.isValidJSONObject(list),
              let fpData = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]) else { return }
        let fingerprint = SHA256.hash(data: fpData).map { String(format: "%02x", $0) }.joined()
        // Nothing to say: no transactions ever, or same list as last time.
        if list.isEmpty && UserDefaults.standard.string(forKey: fingerprintKey) == nil { return }
        if UserDefaults.standard.string(forKey: fingerprintKey) == fingerprint { return }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/ingest/transactions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userID,
            "sdk": "ios/\(FirstFew.sdkVersion)",
            "transactions": list,
        ])
        var delay: TimeInterval = 5
        for attempt in 0..<maxRetries {
            let status = await send(req)
            switch status {
            case 200:
                UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
                return
            case 400, 401, 402, 413:
                return // unrecoverable client error: try again with the next change
            default:
                // Network failure / 429 / 5xx: back off in-session (5, 10, 20, 40s),
                // then leave it to the next launch or foreground.
                if attempt == maxRetries - 1 { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 40)
            }
        }
    }

    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
    private static func send(_ req: URLRequest) async -> Int {
        await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                cont.resume(returning: (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }.resume()
        }
    }

    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
    private static func productType(_ t: Product.ProductType) -> String {
        switch t {
        case .autoRenewable: return "auto_renewable"
        case .nonRenewable: return "non_renewing"
        case .consumable: return "consumable"
        case .nonConsumable: return "non_consumable"
        default: return t.rawValue
        }
    }
    #endif

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
