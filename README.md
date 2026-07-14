# Octri Monitoring for Swift

Standalone events, error capture, W3C trace propagation, and span ingestion for
Swift 5.7+ on Apple platforms.

```swift
import OctriMonitoring

Octri.initialize(.init(
    url: "https://monitoring.example.com",
    token: ProcessInfo.processInfo.environment["OCTRI_TOKEN"],
    environment: "<your project id>",
    release: ProcessInfo.processInfo.environment["GIT_SHA"]
))

Octri.captureEvent("checkout.completed", options: .init(
    tags: ["region": "eu-west", "plan": "growth"],
    context: ["orderId": order.id, "total": order.total]
))
```

The project-scoped URL, token, and environment are shown in Octri's Monitoring
connection settings. Set `token: nil` only for an open self-hosted endpoint.
Delivery is asynchronous, best-effort, and idempotency-keyed.
