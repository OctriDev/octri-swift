import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OctriMonitoring

private final class ScrubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handler?(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 202,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func scrubRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

final class ScrubTests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCTAssertTrue(URLProtocol.registerClass(ScrubURLProtocol.self))
        Octri.initialize(.init(
            url: "https://monitoring.example.com/",
            token: nil,
            environment: "project-1"
        ))
    }

    override func tearDown() {
        ScrubURLProtocol.handler = nil
        URLProtocol.unregisterClass(ScrubURLProtocol.self)
        Octri.setBeforeSend(nil)
        super.tearDown()
    }

    /// Runs `emit` and returns the first payload the reporter posts.
    private func capture(
        _ emit: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let received = expectation(description: "ingest request")
        var payload: [String: Any]?
        ScrubURLProtocol.handler = { request in
            guard payload == nil else { return }
            if let body = scrubRequestBody(request) {
                payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            received.fulfill()
        }
        emit()
        wait(for: [received], timeout: 3)
        return try XCTUnwrap(payload, file: file, line: line)
    }

    // ── Keys ────────────────────────────────────────────────────────────────

    func testCredentialShapedKeysAreRedacted() throws {
        let payload = try capture {
            Octri.captureEvent("checkout failed", options: .init(context: [
                "api_key": "sk_live_1",
                "apiKey": "sk_live_2",
                "X-API-KEY": "sk_live_3",
                "stripeSecretKey": "sk_live_4",
                "Authorization": "Bearer abc",
                "refresh_token": "rt_1",
                "cookie": "sid=1",
                "orderId": "A-1024",
                "author": "ada"
            ]))
        }

        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        for key in [
            "api_key", "apiKey", "X-API-KEY", "stripeSecretKey",
            "Authorization", "refresh_token", "cookie"
        ] {
            XCTAssertEqual(context[key] as? String, "[redacted]", key)
        }
        XCTAssertEqual(context["orderId"] as? String, "A-1024")
        XCTAssertEqual(context["author"] as? String, "ada")
    }

    func testNestedAndArrayValuesAreRedacted() throws {
        let payload = try capture {
            Octri.captureEvent("upstream rejected the call", options: .init(context: [
                "upstream": ["headers": [["authorization": "Bearer abc"]]]
            ]))
        }

        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        let upstream = try XCTUnwrap(context["upstream"] as? [String: Any])
        let headers = try XCTUnwrap(upstream["headers"] as? [[String: Any]])
        XCTAssertEqual(headers.first?["authorization"] as? String, "[redacted]")
    }

    func testAddScrubFieldsIsAdditive() throws {
        Octri.addScrubFields("accountNumber")
        let payload = try capture {
            Octri.captureEvent("payout failed", options: .init(context: [
                "accountNumber": "12345678",
                "orderId": "A-1024"
            ]))
        }

        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["accountNumber"] as? String, "[redacted]")
        XCTAssertEqual(context["orderId"] as? String, "A-1024")
    }

    // ── Free text ───────────────────────────────────────────────────────────

    func testSecretsInFreeTextAreStripped() throws {
        var payload = try capture {
            Octri.captureEvent("401 from billing: Authorization: Bearer sk_live_abc123 rejected")
        }
        var message = try XCTUnwrap(payload["message"] as? String)
        XCTAssertFalse(message.contains("sk_live_abc123"))
        XCTAssertTrue(message.contains("[redacted]"))

        payload = try capture {
            Octri.captureEvent("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.7Hk2 expired")
        }
        message = try XCTUnwrap(payload["message"] as? String)
        XCTAssertEqual(message, "token [redacted] expired")

        payload = try capture { Octri.captureEvent("no account for ada@example.com") }
        message = try XCTUnwrap(payload["message"] as? String)
        XCTAssertEqual(message, "no account for [redacted]")
    }

    func testCardNumbersAreStrippedButOrderNumbersAreNot() throws {
        let payload = try capture {
            Octri.captureEvent("charge 4242 4242 4242 4242 failed for order 1234567890123")
        }

        let message = try XCTUnwrap(payload["message"] as? String)
        XCTAssertFalse(message.contains("4242"), message)
        XCTAssertTrue(message.contains("1234567890123"), message)
    }

    // ── The user field ──────────────────────────────────────────────────────

    // The identity the dashboard keys on is "id", which survives. Direct
    // identifiers under the user are redacted like they are in every generated SDK.
    func testUserIdSurvivesButUserCredentialsAndIdentifiersDoNot() throws {
        let payload = try capture {
            Octri.captureEvent("profile update failed", options: .init(user: [
                "id": "u_1",
                "email": "ada@example.com",
                "sessionToken": "st_1",
                "customerPhone": "+1 555 0100"
            ], context: [
                "billingAddress": "1 High St",
                "avatarUrl": "https://cdn.example.com/a.png",
                "queryTimeMs": 12
            ]))
        }

        let user = try XCTUnwrap(payload["user"] as? [String: Any])
        XCTAssertEqual(user["id"] as? String, "u_1")
        XCTAssertEqual(user["email"] as? String, "[redacted]")
        XCTAssertEqual(user["sessionToken"] as? String, "[redacted]")
        XCTAssertEqual(user["customerPhone"] as? String, "[redacted]")
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["billingAddress"] as? String, "[redacted]")
        XCTAssertEqual(context["avatarUrl"] as? String, "https://cdn.example.com/a.png")
        XCTAssertEqual(context["queryTimeMs"] as? Int, 12)
    }

    // ── setBeforeSend ───────────────────────────────────────────────────────

    func testBeforeSendEditsThenRedactionRuns() throws {
        Octri.setBeforeSend { payload in
            var edited = payload
            edited["context"] = ["note": "call ada@example.com"]
            return edited
        }

        let payload = try capture { Octri.captureEvent("build failed") }
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["note"] as? String, "call [redacted]")
    }

    func testBeforeSendReturningNilDropsTheEvent() throws {
        Octri.setBeforeSend { payload in
            payload["message"] as? String == "noise" ? nil : payload
        }

        let payload = try capture {
            Octri.captureEvent("noise")
            Octri.captureEvent("signal")
        }
        XCTAssertEqual(payload["message"] as? String, "signal")
    }
}
