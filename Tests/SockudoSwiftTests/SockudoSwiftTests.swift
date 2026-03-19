import CryptoKit
import Foundation
import Testing

@testable import SockudoSwift

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private struct TimeoutError: Error {}

private func waitForValue<T>(
    timeout: TimeInterval = 5,
    pollInterval: UInt64 = 50_000_000,
    _ body: @escaping () -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = body() {
            return value
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    throw TimeoutError()
}

private func sha256HMAC(_ string: String, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let signature = HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: key)
    return signature.map { String(format: "%02x", $0) }.joined()
}

private func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func publishToLocalSockudo(
    channel: String,
    eventName: String,
    payload: [String: Any]
) async throws {
    let path = "/apps/app-id/events"
    let eventData = try JSONSerialization.data(withJSONObject: payload, options: [])
    let bodyObject: [String: Any] = [
        "name": eventName,
        "channels": [channel],
        "data": String(decoding: eventData, as: UTF8.self),
    ]
    let body = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
    let bodyMD5 = md5Hex(body)
    let timestamp = String(Int(Date().timeIntervalSince1970))
    let queryItems = [
        ("auth_key", "app-key"),
        ("auth_timestamp", timestamp),
        ("auth_version", "1.0"),
        ("body_md5", bodyMD5),
    ]
    let canonicalQuery =
        queryItems
        .sorted { $0.0 < $1.0 }
        .map { "\($0)=\($1)" }
        .joined(separator: "&")
    let stringToSign = "POST\n\(path)\n\(canonicalQuery)"
    let signature = sha256HMAC(stringToSign, secret: "app-secret")

    guard
        let url = URL(
            string: "http://127.0.0.1:6001\(path)?\(canonicalQuery)&auth_signature=\(signature)")
    else {
        throw TimeoutError()
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (_, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    #expect(statusCode == 200 || statusCode == 202)
}

@Test
func filterValidationAcceptsNestedFilters() {
    let filter = Filter.or(
        .init(key: "sport", cmp: "eq", val: "football"),
        Filter.and(
            Filter.eq("type", "goal"),
            Filter.gte("xg", "0.8")
        )
    )

    #expect(validateFilter(filter) == nil)
}

@Test
func filterValidationRejectsInvalidNotNode() {
    let invalid = FilterNode(op: "not", nodes: [])
    #expect(validateFilter(invalid) == "NOT operation requires exactly one child node, got 0")
}

@Test
func deltaSettingsSerializeAsExpected() {
    #expect(ChannelDeltaSettings(enabled: true).subscriptionValue() as? Bool == true)
    #expect(ChannelDeltaSettings(enabled: false).subscriptionValue() as? Bool == false)
    #expect(ChannelDeltaSettings(algorithm: .fossil).subscriptionValue() as? String == "fossil")
}

@Test
func localSockudoIntegrationConnectsAndReceivesPublishedEvent() async throws {
    guard ProcessInfo.processInfo.environment["SOCKUDO_LIVE_TESTS"] == "1" else {
        return
    }

    let connected = Box<Bool>()
    let subscribed = Box<Bool>()
    let received = Box<[String: Any]>()

    let client = try SockudoClient(
        "app-key",
        options: .init(
            cluster: "local",
            forceTLS: false,
            enabledTransports: [.ws],
            wsHost: "127.0.0.1",
            wsPort: 6001,
            wssPort: 6001
        )
    )

    let channel = client.subscribe("public-updates")
    client.bind("connected") { _, _ in
        connected.value = true
    }
    channel.bind("pusher:subscription_succeeded") { _, _ in
        subscribed.value = true
    }
    channel.bind("integration-event") { data, _ in
        received.value = data as? [String: Any]
    }

    client.connect()

    _ = try await waitForValue { connected.value }
    _ = try await waitForValue { subscribed.value }

    try await publishToLocalSockudo(
        channel: "public-updates",
        eventName: "integration-event",
        payload: [
            "message": "hello from test",
            "item_id": "swift-client",
            "padding": String(repeating: "x", count: 140),
        ]
    )

    let payload = try await waitForValue(timeout: 8) { received.value }
    #expect(payload["message"] as? String == "hello from test")
    client.disconnect()
}
