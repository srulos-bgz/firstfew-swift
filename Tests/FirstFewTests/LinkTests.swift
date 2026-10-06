import XCTest
@testable import FirstFew

final class LinkTests: XCTestCase {
    private let fields = Link.Fields(id: "3f2a9c1e-7b44-4d0e-9a1b-2c3d4e5f6a7b", externalID: "acct-7",
                                     appVersion: "2.4.1 (87)", osVersion: "18.6", deviceModel: "iPhone17,2",
                                     language: "zh-Hans-CN", country: "US")

    private func items(_ url: URL?) -> [(String, String?)] {
        (URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value) }
    }

    func testClaimsOnlyFirstFewSchemes() {
        XCTAssertTrue(Link.isFirstFewLink(URL(string: "ff6478123456://forward")!))
        XCTAssertTrue(Link.isFirstFewLink(URL(string: "FF6478123456://")!))
        XCTAssertFalse(Link.isFirstFewLink(URL(string: "ff://forward")!))
        XCTAssertFalse(Link.isFirstFewLink(URL(string: "ffabc://forward")!))
        XCTAssertFalse(Link.isFirstFewLink(URL(string: "https://example.com/ff123")!))
        XCTAssertFalse(Link.isFirstFewLink(URL(string: "myapp://ff123")!))
    }

    func testForwardAppendsIdAndRequestedValues() {
        let link = Link(url: URL(string: "ff6478123456://forward?forwardUrl=https://baidu.com&app_version&language")!)!
        let target = link.target(fields)
        XCTAssertEqual(target?.scheme, "https")
        XCTAssertEqual(target?.host, "baidu.com")
        XCTAssertEqual(items(target).map { $0.0 }, ["ff_id", "ff_app_version", "ff_language"])
        XCTAssertEqual(items(target).map { $0.1 }, [fields.id, "2.4.1 (87)", "zh-Hans-CN"])
        XCTAssertEqual(link.eventProperties(target)?["to"] as? String, "https://baidu.com")
    }

    func testTargetOwnParamsNeverCollide() {
        // The target already has id= and language= of its own: ours arrive as ff_* beside them.
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https%3A%2F%2Fx.com%2Fp%3Fid%3D123%26language%3Dfr&language")!)!
        XCTAssertEqual(items(link.target(fields)).map { "\($0.0)=\($0.1 ?? "")" },
                       ["id=123", "language=fr", "ff_id=\(fields.id)", "ff_language=zh-Hans-CN"])
    }

    func testTargetKeepsItsOwnQueryAndFragment() {
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https%3A%2F%2Fx.com%2Fp%3Fa%3D1%26b%3D2%23top&country")!)!
        let target = link.target(fields)
        XCTAssertEqual(target?.path, "/p")
        XCTAssertEqual(target?.fragment, "top")
        XCTAssertEqual(items(target).map { $0.0 }, ["a", "b", "ff_id", "ff_country"])
    }

    func testUnencodedTargetQueryLosesItsTail() {
        // `&` not encoded: b=2 is read as a request for a value named "b", which
        // does not exist — the docs say to percent-encode forwardUrl.
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https://x.com/p?a=1&b=2")!)!
        XCTAssertEqual(items(link.target(fields)).map { $0.0 }, ["a", "ff_id"])
    }

    func testEveryValueComesUnderItsFixedKey() {
        let link = Link(url: URL(string:
            "ff1://forward?forwardUrl=https://x.com&external_id&app_version&os_version&device_model&language&country&unknown&App_Version")!)!
        let got = items(link.target(fields))
        XCTAssertEqual(got.map { $0.0 }, ["ff_id", "ff_external_id", "ff_app_version", "ff_os_version", "ff_device_model", "ff_language", "ff_country"])
        let dict = Dictionary(uniqueKeysWithValues: got.map { ($0.0, $0.1 ?? "") })
        XCTAssertEqual(dict["ff_id"], fields.id)
        XCTAssertEqual(dict["ff_external_id"], "acct-7")
        XCTAssertEqual(dict["ff_app_version"], "2.4.1 (87)")
        XCTAssertEqual(dict["ff_os_version"], "18.6")
        XCTAssertEqual(dict["ff_device_model"], "iPhone17,2")
        XCTAssertEqual(dict["ff_language"], "zh-Hans-CN")
        XCTAssertEqual(dict["ff_country"], "US")
    }

    func testMissingExternalIdIsEmpty() {
        var f = fields
        f.externalID = nil
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https://x.com&external_id")!)!
        XCTAssertEqual(items(link.target(f)).last?.1, "")
    }

    func testIdIsAlwaysTheDevicesOwnAndSentOnce() {
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https://x.com&id=mine&id&name=x")!)!
        XCTAssertEqual(items(link.target(fields)).map { "\($0.0)=\($0.1 ?? "")" }, ["ff_id=\(fields.id)"])
    }

    func testForwardsToAnotherAppScheme() {
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=otherapp://open/page&language")!)!
        let target = link.target(fields)
        XCTAssertEqual(target?.scheme, "otherapp")
        XCTAssertEqual(items(target).map { $0.0 }, ["ff_id", "ff_language"])
        XCTAssertEqual(link.eventProperties(target)?["to"] as? String, "otherapp://open")
    }

    func testSchemeOnlyTargetReportsScheme() {
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=otherapp://")!)!
        let target = link.target(fields)
        XCTAssertEqual(target?.absoluteString, "otherapp://?ff_id=\(fields.id)")
        XCTAssertEqual(link.eventProperties(target)?["to"] as? String, "otherapp://")
    }

    func testNoForwardJustOpensTheApp() {
        let link = Link(url: URL(string: "ff1://forward")!)!
        XCTAssertNil(link.forwardTarget)
        XCTAssertNil(link.target(fields))
        XCTAssertNil(link.eventProperties(nil))
        XCTAssertNil(Link(url: URL(string: "ff1://forward?forwardUrl=")!)!.target(fields))
    }

    func testRejectsLoopsAndGarbage() {
        XCTAssertNil(Link(url: URL(string: "ff1://forward?forwardUrl=ff1://forward")!)!.target(fields))
        XCTAssertNil(Link(url: URL(string: "ff1://forward?forwardUrl=FF1://x")!)!.target(fields))
        XCTAssertNil(Link(url: URL(string: "ff1://forward?forwardUrl=no-scheme-here")!)!.target(fields))
        XCTAssertNil(Link(url: URL(string: "ff1://forward?forwardUrl=%20")!)!.target(fields))
    }

    func testEventPropertiesNeverCarryTheQuery() {
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https://x.com/a/b?secret=1&t=2")!)!
        let props = link.eventProperties(link.target(fields))
        XCTAssertEqual(props?.count, 1)
        XCTAssertEqual(props?["to"] as? String, "https://x.com")
    }

    func testEventPropertiesRecordTheCheckOutcome() {
        let link = Link(url: URL(string: "ff1://forward?forwardUrl=https://x.com/p")!)!
        let target = link.target(fields)
        XCTAssertEqual(link.eventProperties(target, allowed: false)?["blocked"] as? Bool, true)
        XCTAssertNil(link.eventProperties(target, allowed: false)?["offline"])
        XCTAssertEqual(link.eventProperties(target, allowed: nil)?["offline"] as? Bool, true)
        XCTAssertNil(link.eventProperties(target, allowed: nil)?["blocked"])
        XCTAssertEqual(link.eventProperties(target, allowed: true)?.count, 1)
    }

    func testDestinationIsSchemeAndHostOnly() {
        XCTAssertEqual(Link.destination(URL(string: "https://Example.com/a?b=1#c")!), "https://Example.com")
        XCTAssertEqual(Link.destination(URL(string: "otherapp://open/x?y=1")!), "otherapp://open")
        XCTAssertEqual(Link.destination(URL(string: "otherapp://")!), "otherapp://")
    }
}
