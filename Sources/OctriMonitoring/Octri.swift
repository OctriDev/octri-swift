import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OctriConfig {
    public let url: String
    /// Optional only for open self-hosted ingestion. Hosted Octri requires it.
    public let token: String?
    public let environment: String
    public let release: String?

    public init(url: String, token: String?, environment: String, release: String? = nil) {
        self.url = url.replacingOccurrences(of: #"/+\z"#, with: "", options: .regularExpression)
        self.token = token
        self.environment = environment
        self.release = release
    }
}

public struct OctriTraceContext: Equatable {
    public let traceId: String
    public let parentSpanId: String?

    public init(traceId: String, parentSpanId: String? = nil) {
        self.traceId = traceId
        self.parentSpanId = parentSpanId
    }
}

public struct OctriEventOptions {
    public var timestamp: Date?
    public var level: String
    public var operationId: String?
    public var method: String?
    public var path: String?
    public var statusCode: Int?
    public var latencyMs: Double?
    public var attempt: Int?
    public var requestId: String?
    public var user: [String: Any]?
    public var tags: [String: Any]?
    public var context: [String: Any]?
    public var breadcrumbs: [[String: Any]]?
    public var fingerprint: String?
    public var trace: OctriTraceContext?
    public var spanId: String?
    public var eventId: String?

    public init(
        timestamp: Date? = nil,
        level: String = "info",
        operationId: String? = nil,
        method: String? = nil,
        path: String? = nil,
        statusCode: Int? = nil,
        latencyMs: Double? = nil,
        attempt: Int? = nil,
        requestId: String? = nil,
        user: [String: Any]? = nil,
        tags: [String: Any]? = nil,
        context: [String: Any]? = nil,
        breadcrumbs: [[String: Any]]? = nil,
        fingerprint: String? = nil,
        trace: OctriTraceContext? = nil,
        spanId: String? = nil,
        eventId: String? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.operationId = operationId
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.latencyMs = latencyMs
        self.attempt = attempt
        self.requestId = requestId
        self.user = user
        self.tags = tags
        self.context = context
        self.breadcrumbs = breadcrumbs
        self.fingerprint = fingerprint
        self.trace = trace
        self.spanId = spanId
        self.eventId = eventId
    }
}

public struct OctriErrorOptions {
    public var level: String
    public var operationId: String?
    public var method: String?
    public var path: String?
    public var statusCode: Int?
    public var trace: OctriTraceContext?

    public init(
        level: String = "error",
        operationId: String? = nil,
        method: String? = nil,
        path: String? = nil,
        statusCode: Int? = nil,
        trace: OctriTraceContext? = nil
    ) {
        self.level = level
        self.operationId = operationId
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.trace = trace
    }
}

public struct OctriSpan {
    public var traceId: String
    public var spanId: String
    public var parentSpanId: String?
    public var name: String
    public var service: String
    public var operationId: String?
    public var startTime: Date
    public var endTime: Date?
    public var status: String

    public init(
        traceId: String,
        spanId: String,
        parentSpanId: String? = nil,
        name: String,
        service: String = "server",
        operationId: String? = nil,
        startTime: Date,
        endTime: Date? = nil,
        status: String = "ok"
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.name = name
        self.service = service
        self.operationId = operationId
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
    }
}

/// Standalone Octri monitoring. All reporting is asynchronous and best-effort.
public enum Octri {
    private static let lock = NSLock()
    private static var config: OctriConfig?

    public static func initialize(_ value: OctriConfig) {
        lock.lock()
        config = value
        lock.unlock()
    }

    public static func traceFromHeader(_ traceparent: String?) -> OctriTraceContext {
        if let value = traceparent?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 4,
               parts[0] == "00",
               isHex(parts[1], length: 32),
               isHex(parts[2], length: 16),
               isHex(parts[3], length: 2),
               !allZeros(parts[1]),
               !allZeros(parts[2]) {
                return OctriTraceContext(
                    traceId: parts[1].lowercased(),
                    parentSpanId: parts[2].lowercased()
                )
            }
        }
        return OctriTraceContext(traceId: randomHex(bytes: 16))
    }

    /// Log an event without depending on a generated Octri API SDK.
    public static func captureEvent(_ message: String, options: OctriEventOptions = .init()) {
        guard let config = currentConfig() else { return }
        let eventId = options.eventId.flatMap { safeHeaderValue($0) ? $0 : nil }
            ?? randomHex(bytes: 16)
        var tags: [String: Any] = ["octri.origin": "standalone"]
        options.tags?.forEach { tags[$0.key] = $0.value }
        var payload: [String: Any] = [
            "eventId": eventId,
            "timestamp": iso(options.timestamp ?? Date()),
            "level": options.level,
            "message": message,
            "environment": config.environment,
            "tags": tags,
        ]
        put(&payload, "release", config.release)
        put(&payload, "operationId", options.operationId)
        put(&payload, "method", options.method)
        put(&payload, "path", options.path)
        put(&payload, "statusCode", options.statusCode)
        put(&payload, "latencyMs", options.latencyMs)
        put(&payload, "attempt", options.attempt)
        put(&payload, "requestId", options.requestId)
        put(&payload, "user", options.user)
        put(&payload, "context", options.context)
        put(&payload, "breadcrumbs", options.breadcrumbs)
        put(&payload, "fingerprint", options.fingerprint)
        put(&payload, "traceId", options.trace?.traceId)
        put(&payload, "spanId", options.spanId)
        post(config, path: "/ingest", payload: payload, idempotencyKey: eventId)
    }

    public static func captureError(_ error: Error, options: OctriErrorOptions = .init()) {
        guard let config = currentConfig() else { return }
        let trace = options.trace ?? traceFromHeader(nil)
        let eventId = randomHex(bytes: 16)
        var payload: [String: Any] = [
            "eventId": eventId,
            "timestamp": iso(Date()),
            "level": options.level,
            "environment": config.environment,
            "traceId": trace.traceId,
            "spanId": randomHex(bytes: 8),
            "tags": ["octri.origin": "server"],
            "error": [
                "name": String(reflecting: type(of: error)),
                "message": String(describing: error),
                "stack": Thread.callStackSymbols.joined(separator: "\n"),
                "frames": [],
            ],
        ]
        put(&payload, "release", config.release)
        put(&payload, "operationId", options.operationId)
        put(&payload, "method", options.method)
        put(&payload, "path", options.path)
        put(&payload, "statusCode", options.statusCode)
        post(config, path: "/ingest", payload: payload, idempotencyKey: eventId)
    }

    public static func captureSpan(_ span: OctriSpan) {
        guard let config = currentConfig() else { return }
        guard !span.traceId.isEmpty, !span.spanId.isEmpty, !span.name.isEmpty else { return }
        var payload: [String: Any] = [
            "traceId": span.traceId,
            "spanId": span.spanId,
            "environment": config.environment,
            "name": span.name,
            "service": span.service,
            "startTime": iso(span.startTime),
            "status": span.status,
        ]
        put(&payload, "parentSpanId", span.parentSpanId)
        put(&payload, "operationId", span.operationId)
        if let endTime = span.endTime { payload["endTime"] = iso(endTime) }
        post(
            config,
            path: "/traces",
            payload: payload,
            idempotencyKey: "\(span.traceId):\(span.spanId)"
        )
    }

    private static func currentConfig() -> OctriConfig? {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    private static func post(
        _ config: OctriConfig,
        path: String,
        payload: [String: Any],
        idempotencyKey: String
    ) {
        guard safeHeaderValue(idempotencyKey),
              config.token.map({ $0.isEmpty || safeHeaderValue($0) }) ?? true else { return }
        guard JSONSerialization.isValidJSONObject(payload),
              let url = URL(string: config.url + path),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "idempotency-key")
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        URLSession.shared.dataTask(with: request).resume()
    }

    private static func put(_ target: inout [String: Any], _ key: String, _ value: Any?) {
        if let value = value { target[key] = value }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isHex(_ value: Substring, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit }
    }

    private static func allZeros(_ value: Substring) -> Bool {
        value.allSatisfy { $0 == "0" }
    }

    private static func safeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            $0.value == 0x0D || $0.value == 0x0A
        }
    }

    private static func randomHex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }
}
