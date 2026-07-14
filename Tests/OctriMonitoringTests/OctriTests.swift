import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OctriMonitoring

private final class StubURLProtocol: URLProtocol {
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

private func requestBody(_ request: URLRequest) -> Data? {
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

final class OctriTests: XCTestCase {
    func testTraceparentParsing() {
        let trace = Octri.traceFromHeader(
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        )
        XCTAssertEqual(trace.traceId, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(trace.parentSpanId, "00f067aa0ba902b7")
    }

    func testRejectsZeroTraceparentIdentifiers() {
        let trace = Octri.traceFromHeader(
            "00-00000000000000000000000000000000-0000000000000000-01"
        )
        XCTAssertTrue(trace.traceId.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil)
        XCTAssertNotEqual(trace.traceId, String(repeating: "0", count: 32))
        XCTAssertNil(trace.parentSpanId)
    }

    func testCaptureEventScopesAuthAndReplacesUnsafeIdempotencyKey() throws {
        let received = expectation(description: "event request")
        XCTAssertTrue(URLProtocol.registerClass(StubURLProtocol.self))
        defer {
            StubURLProtocol.handler = nil
            URLProtocol.unregisterClass(StubURLProtocol.self)
        }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://monitoring.example.com/ingest")
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer project-token")
            let key = request.value(forHTTPHeaderField: "idempotency-key")
            XCTAssertTrue(key?.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil)
            let body = try! JSONSerialization.jsonObject(with: requestBody(request)!) as! [String: Any]
            XCTAssertEqual(body["eventId"] as? String, key)
            XCTAssertEqual(body["environment"] as? String, "project-1")
            XCTAssertEqual(body["message"] as? String, "checkout.completed")
            received.fulfill()
        }

        Octri.initialize(.init(
            url: "https://monitoring.example.com/",
            token: "project-token",
            environment: "project-1"
        ))
        Octri.captureEvent("checkout.completed", options: .init(
            tags: ["plan": "growth"],
            eventId: "unsafe\r\nX-Injected: true"
        ))
        wait(for: [received], timeout: 3)
    }
}
