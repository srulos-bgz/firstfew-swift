import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit)
import UIKit
#endif

extension FirstFew {
    /// A temporary sale on an in-app purchase, set up in the FirstFew console
    /// (SKU management ▸ temporary sale) for the device's App Store region.
    ///
    /// StoreKit alone only knows the current price — during a sale that *is* the
    /// sale price, with no regular price and no end date. `Sale` adds both, so the
    /// app can show "~~$4.99~~ $2.49 · ends Oct 9". The current price to display is
    /// still StoreKit's own (`product.displayPrice`).
    public struct Sale: Equatable {
        /// The product identifier (App Store Connect product id).
        public let productId: String
        /// Regular price in the storefront's currency.
        public let regularPrice: Decimal
        /// Sale price in the storefront's currency — equal to StoreKit's current price.
        public let salePrice: Decimal
        /// ISO 4217 currency code of both prices.
        public let currency: String
        /// The discount in this region, rounded down (never overstated).
        public let discountPercent: Int
        /// The regular price formatted the way StoreKit formats this product's price.
        public let regularDisplayPrice: String
        /// When the sale started in this region; `nil` when it started immediately.
        public let startsAt: Date?
        /// When the regular price is back in this region (from the server, per the
        /// App Store's release schedule for the region).
        public let endsAt: Date
    }

    /// The temporary sales of this device's App Store region, from `FirstFew.sales()`.
    public struct Sales {
        let cache: SaleStore.Cache?

        #if canImport(StoreKit)
        /// The sale running on `product`, or `nil`.
        @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
        public func sale(for product: Product) -> Sale? {
            SaleStore.match(product, cache: cache)
        }

        /// StoreKit 1 variant of `sale(for:)`.
        public func sale(for product: SKProduct) -> Sale? {
            SaleStore.match(product, cache: cache)
        }
        #endif
    }

    /// All temporary sales of this device's App Store region; look a product up with
    /// `sale(for:)`, passing the StoreKit product the app has already loaded:
    /// ```swift
    /// let sales = await FirstFew.sales()
    /// if let sale = sales.sale(for: product) { … }
    /// ```
    /// The sales are fetched once per app launch. On a new install with no sale data yet,
    /// it returns once the data arrives — including after the user allows network access on
    /// first launch — so call it from the paywall's `.task`, never in a way that blocks
    /// showing the screen.
    public static func sales() async -> Sales {
        await SaleStore.answer()
        return Sales(cache: SaleStore.snapshot())
    }
}

/// Fetches and caches the temporary sales of the device's App Store region
/// (`GET /api/ingest/sales?storefront=XXX`); the cache survives launches.
enum SaleStore {
    struct Entry: Codable, Equatable {
        let productId: String
        let regularPrice: Double
        let salePrice: Double
        let currency: String
        let discountPercent: Int
        let startsAt: Date?
        let endsAt: Date

        enum CodingKeys: String, CodingKey {
            case productId = "product_id", regularPrice = "regular_price", salePrice = "sale_price", currency
            case discountPercent = "discount_pct", startsAt = "starts_at", endsAt = "ends_at"
        }
    }

    struct Cache: Codable, Equatable {
        let storefront: String
        let sales: [Entry]
    }

    private static let cacheKey = "com.firstfew.sdk.sales"
    private static let lock = NSLock()
    private static var cache: Cache? = loadCache()
    private static var ingest: (token: String, baseURL: URL)?
    /// Storefront of this launch's successful fetch; `nil` = not fetched yet this launch.
    /// One successful fetch per launch — no more requests until the next cold start.
    private static var fetchedFor: String?
    private static var inFlight = false
    /// `sales()` callers waiting for an answer.
    private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private static var pathMonitor: AnyObject?
    /// Server time at this launch's successful fetch (the response's `Date` header) and the
    /// monotonic clock at that moment. "Now" = server time + time elapsed since — the phone's
    /// own clock (which the user can change) is never used.
    private static var anchor: (server: Date, mono: TimeInterval)?

    /// Seconds on a monotonic clock that keeps counting while the device sleeps and ignores
    /// changes to the phone's date and time.
    private static func monotonic() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// Server time now, or `nil` when this launch has not reached the server yet.
    static func serverNow() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let anchor else { return nil }
        return anchor.server.addingTimeInterval(monotonic() - anchor.mono)
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private enum Outcome { case ok, noNetwork, failed }

    static func start(token: String, baseURL: URL) {
        lock.lock()
        let first = ingest == nil
        ingest = (token, baseURL)
        lock.unlock()
        guard first else { return }
        // Fetch right away; until one fetch succeeds, try again the moment there is a chance
        // to succeed — no timers, no backoff: a new user's onboarding paywall must get the
        // sales as soon as possible.
        kick()
        #if canImport(UIKit)
        // Becoming active covers returning to the foreground and the dismissal of system
        // alerts — including the network-access prompt shown on first launch in mainland China.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in kick() }
        #endif
        #if canImport(StoreKit)
        // The user switched App Store account / region: prices change with it.
        NotificationCenter.default.addObserver(
            forName: Notification.Name.SKStorefrontCountryCodeDidChange, object: nil, queue: nil
        ) { _ in
            lock.lock()
            fetchedFor = nil
            lock.unlock()
            kick()
        }
        #endif
        #if canImport(Network)
        if #available(iOS 12, macOS 10.14, tvOS 12, watchOS 5, *) {
            // Network went from unavailable to available (network access allowed, Wi-Fi back…).
            let monitor = NWPathMonitor()
            var wasSatisfied: Bool?
            monitor.pathUpdateHandler = { path in
                let satisfied = path.status == .satisfied
                if satisfied, wasSatisfied == false { kick() }
                wasSatisfied = satisfied
            }
            monitor.start(queue: DispatchQueue(label: "com.firstfew.sdk.sales.path"))
            pathMonitor = monitor
        }
        #endif
    }

    /// The device's App Store region (ISO 3166-1 alpha-3). Read synchronously from
    /// StoreKit's local state — no network request.
    static func currentStorefront() -> String? {
        #if canImport(StoreKit)
        if let code = SKPaymentQueue.default().storefront?.countryCode, code.count == 3 {
            return code.uppercased()
        }
        #endif
        return nil
    }

    /// Fetched successfully this launch, for the storefront the device is on now.
    private static func isFreshLocked() -> Bool {
        guard let fetched = fetchedFor else { return false }
        if let now = currentStorefront(), now != fetched { return false }
        return true
    }

    private static func readyNow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ingest == nil || isFreshLocked()
    }

    /// Waits for an answer: returns at once once this launch has fetched; otherwise fetches
    /// now and returns when it lands. Without network it returns the cached copy from an
    /// earlier launch if there is one, and otherwise (a new install) keeps waiting until a
    /// later attempt succeeds. Cancelling the calling task ends the wait.
    static func answer() async {
        if readyNow() { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if Task.isCancelled || isFreshLocked() {
                    lock.unlock()
                    cont.resume()
                    return
                }
                waiters[id] = cont
                lock.unlock()
                kick()
            }
        } onCancel: {
            lock.lock()
            let cont = waiters.removeValue(forKey: id)
            lock.unlock()
            cont?.resume()
        }
    }

    /// Fetches now unless a request is already running or there is a fresh answer nobody
    /// is waiting for.
    static func kick() {
        lock.lock()
        guard let ingest, !inFlight, !(isFreshLocked() && waiters.isEmpty) else {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        if let storefront = currentStorefront() {
            fetch(storefront: storefront, ingest: ingest)
            return
        }
        // StoreKit has not filled in its synchronous storefront yet: ask the async API.
        #if canImport(StoreKit)
        if #available(iOS 15, macOS 12, tvOS 15, watchOS 8, *) {
            Task.detached(priority: .userInitiated) {
                if let code = await Storefront.current?.countryCode, code.count == 3 {
                    fetch(storefront: code.uppercased(), ingest: ingest)
                } else if let cached = cachedStorefront() {
                    fetch(storefront: cached, ingest: ingest)
                } else {
                    finish(.noNetwork, storefront: nil)
                }
            }
            return
        }
        #endif
        if let cached = cachedStorefront() {
            fetch(storefront: cached, ingest: ingest)
        } else {
            finish(.noNetwork, storefront: nil)
        }
    }

    private static func fetch(storefront: String, ingest: (token: String, baseURL: URL)) {
        var comps = URLComponents(url: ingest.baseURL.appendingPathComponent("api/ingest/sales"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "storefront", value: storefront)]
        guard let url = comps?.url else {
            finish(.failed, storefront: storefront)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(ingest.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse else {
                // Never reached the server: no network yet (or network access not allowed).
                finish(.noNetwork, storefront: storefront)
                return
            }
            guard http.statusCode == 200, let data, let parsed = decode(data, storefront: storefront) else {
                finish(.failed, storefront: storefront)
                return
            }
            let serverDate = (http.value(forHTTPHeaderField: "Date")).flatMap { httpDate.date(from: $0) }
            lock.lock()
            cache = parsed
            if let serverDate {
                anchor = (serverDate, monotonic())
            }
            lock.unlock()
            if let encoded = try? encoder.encode(parsed) {
                UserDefaults.standard.set(encoded, forKey: cacheKey)
            }
            finish(.ok, storefront: storefront)
        }.resume()
    }

    /// Ends a fetch and answers the waiters — except a new install without network: those
    /// keep waiting for the next attempt (becoming active, network back, storefront change).
    private static func finish(_ outcome: Outcome, storefront: String?) {
        lock.lock()
        inFlight = false
        if outcome == .ok {
            fetchedFor = storefront
        }
        var ready: [CheckedContinuation<Void, Never>] = []
        if outcome != .noNetwork || cache != nil {
            ready = Array(waiters.values)
            waiters.removeAll()
        }
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    static func decode(_ data: Data, storefront: String) -> Cache? {
        struct Body: Decodable { let sales: [Entry]? }
        guard let body = try? decoder.decode(Body.self, from: data) else { return nil }
        return Cache(storefront: storefront, sales: body.sales ?? [])
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static func loadCache() -> Cache? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? decoder.decode(Cache.self, from: data)
    }

    private static func cachedStorefront() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.storefront
    }

    static func snapshot() -> Cache? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    #if canImport(StoreKit)
    @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
    static func match(_ product: Product, cache: Cache?) -> FirstFew.Sale? {
        match(productId: product.id, price: product.price, currency: product.priceFormatStyle.currencyCode,
              cache: cache, storefront: currentStorefront(), now: serverNow(),
              format: { product.priceFormatStyle.format($0) })
    }

    static func match(_ product: SKProduct, cache: Cache?) -> FirstFew.Sale? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = product.priceLocale
        return match(productId: product.productIdentifier, price: product.price as Decimal,
                     currency: product.priceLocale.currencyCode, cache: cache,
                     storefront: currentStorefront(), now: serverNow(),
                     format: { formatter.string(from: $0 as NSDecimalNumber) ?? "\($0)" })
    }
    #endif

    /// The matching rule, kept pure for tests: the cached list belongs to this App Store
    /// region, it has a sale for this product, the sale has started and not yet ended at
    /// `now` (server time; `nil` when this launch has not reached the server — then only the
    /// price decides), and StoreKit's current price equals the sale price.
    static func match(productId: String, price: Decimal, currency: String?, cache: Cache?,
                      storefront: String?, now: Date?, format: (Decimal) -> String) -> FirstFew.Sale? {
        guard let cache, let entry = cache.sales.first(where: { $0.productId == productId }) else { return nil }
        if let storefront, storefront != cache.storefront { return nil }
        if let now {
            if now >= entry.endsAt { return nil }
            if let start = entry.startsAt, now < start { return nil }
        }
        if let currency, !currency.isEmpty, currency.uppercased() != entry.currency.uppercased() { return nil }
        let sale = Decimal(string: String(entry.salePrice)) ?? Decimal(entry.salePrice)
        guard abs(NSDecimalNumber(decimal: price - sale).doubleValue) < 0.005 else { return nil }
        let regular = Decimal(string: String(entry.regularPrice)) ?? Decimal(entry.regularPrice)
        return FirstFew.Sale(productId: entry.productId, regularPrice: regular, salePrice: sale,
                             currency: entry.currency, discountPercent: entry.discountPercent,
                             regularDisplayPrice: format(regular), startsAt: entry.startsAt, endsAt: entry.endsAt)
    }
}
