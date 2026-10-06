import XCTest
@testable import FirstFew

final class SaleTests: XCTestCase {
    private let body = """
    {"storefront":"USA","sales":[{"product_id":"lifetime","regular_price":4.99,"sale_price":2.49,
    "currency":"USD","discount_pct":50,"starts_at":null,"ends_at":"2026-10-09T03:00:00Z"}]}
    """.data(using: .utf8)!

    private let iso = ISO8601DateFormatter()

    private func match(_ price: Decimal, currency: String? = "USD", storefront: String? = "USA",
                       id: String = "lifetime", now: String? = nil) -> FirstFew.Sale? {
        SaleStore.match(productId: id, price: price, currency: currency,
                        cache: SaleStore.decode(body, storefront: "USA"), storefront: storefront,
                        now: now.flatMap { iso.date(from: $0) }, format: { "$\($0)" })
    }

    func testMatchesWhenStoreKitShowsTheSalePrice() {
        let sale = match(Decimal(string: "2.49")!)
        XCTAssertEqual(sale?.regularPrice, Decimal(string: "4.99"))
        XCTAssertEqual(sale?.salePrice, Decimal(string: "2.49"))
        XCTAssertEqual(sale?.discountPercent, 50)
        XCTAssertEqual(sale?.regularDisplayPrice, "$4.99")
        XCTAssertNil(sale?.startsAt)
    }

    func testEndTimeIsTheServersMomentNotThePhonesClock() {
        // The server computes the region's switch moment; the SDK passes it through untouched.
        XCTAssertEqual(match(Decimal(string: "2.49")!)?.endsAt, ISO8601DateFormatter().date(from: "2026-10-09T03:00:00Z"))
    }

    func testFlipsAtTheEndMomentByServerTime() {
        // 5 seconds before the end: still on sale; at / after the end: gone — even though the
        // Product the app holds still carries the sale price.
        XCTAssertNotNil(match(Decimal(string: "2.49")!, now: "2026-10-09T02:59:55Z"))
        XCTAssertNil(match(Decimal(string: "2.49")!, now: "2026-10-09T03:00:00Z"))
        XCTAssertNil(match(Decimal(string: "2.49")!, now: "2026-10-09T03:00:05Z"))
    }

    func testNoSaleWhenStoreKitStillShowsTheRegularPrice() {
        // Server data ahead of / behind the App Store (edited in App Store Connect, region already switched back).
        XCTAssertNil(match(Decimal(string: "4.99")!))
    }

    func testOtherRegionCurrencyOrProductNeverMatch() {
        XCTAssertNil(match(Decimal(string: "2.49")!, storefront: "GBR"))
        XCTAssertNil(match(Decimal(string: "2.49")!, currency: "GBP"))
        XCTAssertNil(match(Decimal(string: "2.49")!, id: "monthly"))
        // Unknown storefront right now: trust the cached region (the price check still guards).
        XCTAssertNotNil(match(Decimal(string: "2.49")!, storefront: nil))
    }

    func testDecodeToleratesMissingSales() {
        XCTAssertEqual(SaleStore.decode(#"{"storefront":"USA"}"#.data(using: .utf8)!, storefront: "USA")?.sales, [])
        XCTAssertNil(SaleStore.decode(Data("nope".utf8), storefront: "USA"))
    }
}
