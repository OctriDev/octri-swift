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
    private static let maxIdempotencyKeyLength = 256
    private static let lock = NSLock()
    private static var config: OctriConfig?

    public static func initialize(_ value: OctriConfig) {
        lock.lock()
        config = value
        lock.unlock()
    }

    // ── Scrubbing ──────────────────────────────────────────────────────────

    /// Keys whose value never leaves the process. Compared against the key with
    /// case and separators removed, so `api_key`, `apiKey` and `API-KEY` all
    /// match `apikey`, and the test is a substring one, so `stripeSecretKey`
    /// matches too.
    private static let scrubKeys = [
        "password", "passwd", "passphrase", "secret", "token", "apikey",
        "authorization", "credential", "cookie", "session", "privatekey",
        "accesskey", "cardnumber", "creditcard", "cvv", "ssn"
    ]

    private static let redacted = "[redacted]"
    private static let truncated = "[truncated]"
    /// Deep enough for real context dictionaries, shallow enough to stay cheap.
    private static let maxScrubDepth = 8

    private static let bearerExpression =
        expression("\\bbearer\\s+[\\w.~+/-]+=*", caseInsensitive: true)
    private static let jwtExpression = expression("\\beyJ[\\w-]+\\.[\\w-]+\\.[\\w-]+")
    private static let digitRunExpression = expression("\\b(?:\\d[ -]?){12,18}\\d\\b")
    private static let emailExpression = expression("[\\w.%+-]+@[\\w-]+(?:\\.[\\w-]+)+")

    private static var extraScrubKeys: [String] = []
    private static var beforeSend: (([String: Any]) -> [String: Any]?)?

    /// Redacts more key names, on top of the built-in list. Matching ignores
    /// case and separators and is a substring test, so `account` also covers
    /// `accountNumber`.
    ///
    ///     Octri.addScrubFields("accountNumber", "otp")
    public static func addScrubFields(_ fields: String...) {
        lock.lock()
        defer { lock.unlock() }
        for field in fields {
            let key = normalizeKey(field)
            if !key.isEmpty, !extraScrubKeys.contains(key) {
                extraScrubKeys.append(key)
            }
        }
    }

    /// Runs a hook on every payload just before it is sent. Return the payload
    /// to send it, or `nil` to drop the event:
    ///
    ///     Octri.setBeforeSend { payload in
    ///         payload["path"] as? String == "/health" ? nil : payload
    ///     }
    ///
    /// Redaction still runs afterwards, so a hook cannot leak a credential by
    /// accident. Pass `nil` to remove the hook.
    public static func setBeforeSend(_ hook: (([String: Any]) -> [String: Any]?)?) {
        lock.lock()
        beforeSend = hook
        lock.unlock()
    }

    private static func expression(
        _ pattern: String,
        caseInsensitive: Bool = false
    ) -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    private static func normalizeKey(_ key: String) -> String {
        String(key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    private static func isSecretKey(_ key: String, extra: [String]) -> Bool {
        let normalized = normalizeKey(key)
        guard !normalized.isEmpty else { return false }
        return scrubKeys.contains(where: normalized.contains)
            || extra.contains(where: normalized.contains)
    }

    /// Tells a card number from the order ids and timestamps that look like one.
    private static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        var doubling = false
        for character in digits.reversed() {
            guard let value = character.wholeNumberValue else { return false }
            var digit = value
            if doubling {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
            doubling = !doubling
        }
        return sum % 10 == 0
    }

    private static func replacingMatches(
        _ value: String,
        _ expression: NSRegularExpression?
    ) -> String {
        guard let expression else { return value }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: redacted
        )
    }

    /// Digit runs are only redacted when they also pass the Luhn check, so an
    /// order number or a timestamp survives.
    private static func replacingCardNumbers(_ value: String) -> String {
        guard let expression = digitRunExpression else { return value }
        let source = value as NSString
        var result = value
        let matches = expression.matches(
            in: value,
            range: NSRange(location: 0, length: source.length)
        )
        // Back to front, so the ranges found in `value` still line up.
        for match in matches.reversed() {
            let run = source.substring(with: match.range)
            let digits = String(run.filter { $0.isASCII && $0.isNumber })
            guard passesLuhn(digits) else { continue }
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: redacted
            )
        }
        return result
    }

    /// Removes credentials and personal data that leaked into free text.
    private static func scrubText(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var scrubbed = replacingMatches(value, bearerExpression)
        scrubbed = replacingMatches(scrubbed, jwtExpression)
        scrubbed = replacingCardNumbers(scrubbed)
        return replacingMatches(scrubbed, emailExpression)
    }

    /// Redacts credential-shaped keys anywhere in the payload, and strips
    /// secrets out of the free text around them. `user` is the field you
    /// deliberately fill with an identity, so its strings are left alone; its
    /// keys are still checked.
    private static func scrubValue(
        _ value: Any,
        depth: Int,
        text: Bool,
        extra: [String]
    ) -> Any {
        if let string = value as? String {
            return text ? scrubText(string) : string
        }
        if let dictionary = value as? [String: Any] {
            guard depth < maxScrubDepth else { return truncated }
            var out: [String: Any] = [:]
            out.reserveCapacity(dictionary.count)
            for (key, nested) in dictionary {
                out[key] = isSecretKey(key, extra: extra)
                    ? redacted
                    : scrubValue(
                        nested,
                        depth: depth + 1,
                        text: text && key != "user",
                        extra: extra
                    )
            }
            return out
        }
        if let array = value as? [Any] {
            guard depth < maxScrubDepth else { return truncated }
            return array.map {
                scrubValue($0, depth: depth + 1, text: text, extra: extra)
            }
        }
        return value
    }

    /// The last thing every payload passes through. Both the hook and the
    /// redaction live here rather than in the capture functions, so nothing can
    /// be reported around them.
    private static func scrubPayload(_ payload: [String: Any]) -> [String: Any]? {
        lock.lock()
        let hook = beforeSend
        let extra = extraScrubKeys
        lock.unlock()

        var hooked = payload
        if let hook {
            guard let result = hook(payload) else { return nil }
            hooked = result
        }
        return scrubValue(hooked, depth: 0, text: true, extra: extra) as? [String: Any]
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
        let eventId = options.eventId.flatMap { safeIdempotencyKey($0) ? $0 : nil }
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
        guard safeIdempotencyKey(idempotencyKey),
              config.token.map({ $0.isEmpty || safeHeaderValue($0) }) ?? true else { return }
        guard let scrubbed = scrubPayload(payload) else { return }
        guard JSONSerialization.isValidJSONObject(scrubbed),
              let url = URL(string: config.url + path),
              let body = try? JSONSerialization.data(withJSONObject: scrubbed) else { return }
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

    /// A caller-supplied event id becomes the `idempotency-key` header, so it
    /// is bounded as well as newline-free.
    private static func safeIdempotencyKey(_ value: String) -> Bool {
        safeHeaderValue(value) && value.utf8.count <= maxIdempotencyKeyLength
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
