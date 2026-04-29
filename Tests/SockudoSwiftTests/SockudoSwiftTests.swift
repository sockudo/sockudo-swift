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

private func liveWireFormat() -> SockudoWireFormat {
  switch ProcessInfo.processInfo.environment["SOCKUDO_WIRE_FORMAT"]?.lowercased() {
  case "messagepack", "msgpack":
    return .messagepack
  case "protobuf", "proto":
    return .protobuf
  default:
    return .json
  }
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
  #expect(SubscriptionRewind.count(10).subscriptionValue() as? Int == 10)
  #expect((SubscriptionRewind.seconds(30).subscriptionValue() as? [String: Int])?["seconds"] == 30)
}

@Test
func presenceHistoryParamsNormalizeAblyAliases() {
  let payload = PresenceHistoryParams(
    direction: "newest_first",
    limit: 50,
    start: 1000,
    end: 2000
  ).payload

  #expect(payload["direction"] as? String == "newest_first")
  #expect(payload["limit"] as? Int == 50)
  #expect(payload["start_time_ms"] as? Int64 == 1000)
  #expect(payload["end_time_ms"] as? Int64 == 2000)
}

@Test
func presenceHistoryPageNextUsesNextCursor() async throws {
  let cursor = Box<String>()
  let page = PresenceHistoryPage(
    items: [],
    direction: "newest_first",
    limit: 50,
    hasMore: true,
    nextCursor: "cursor-2",
    bounds: .init(startSerial: nil, endSerial: nil, startTimeMS: nil, endTimeMS: nil),
    continuity: .init(
      streamID: nil,
      oldestAvailableSerial: nil,
      newestAvailableSerial: nil,
      oldestAvailablePublishedAtMS: nil,
      newestAvailablePublishedAtMS: nil,
      retainedEvents: 0,
      retainedBytes: 0,
      degraded: false,
      complete: true,
      truncatedByRetention: false
    ),
    fetchNext: { next, completion in
      cursor.value = next
      completion(
        .success(
          PresenceHistoryPage(
            items: [],
            direction: "newest_first",
            limit: 50,
            hasMore: false,
            nextCursor: nil,
            bounds: .init(startSerial: nil, endSerial: nil, startTimeMS: nil, endTimeMS: nil),
            continuity: .init(
              streamID: nil,
              oldestAvailableSerial: nil,
              newestAvailableSerial: nil,
              oldestAvailablePublishedAtMS: nil,
              newestAvailablePublishedAtMS: nil,
              retainedEvents: 0,
              retainedBytes: 0,
              degraded: false,
              complete: true,
              truncatedByRetention: false
            ),
            fetchNext: nil
          )
        ))
    }
  )

  try await withCheckedThrowingContinuation { continuation in
    page.next { result in
      switch result {
      case .success:
        continuation.resume()
      case .failure(let error):
        continuation.resume(throwing: error)
      }
    }
  }

  #expect(cursor.value == "cursor-2")
}

@Test
func annotationRequestPayloadUsesProxyShape() {
  let payload = PublishAnnotationRequest(
    type: "reactions:distinct.v1",
    name: "like",
    count: 2,
    data: ["emoji": .string("thumbs-up")],
    clientID: "client-1",
    extras: ["source": .string("ios")],
    idempotencyKey: "anno-1"
  ).payload

  #expect(payload["type"] as? String == "reactions:distinct.v1")
  #expect(payload["name"] as? String == "like")
  #expect(payload["count"] as? Int == 2)
  #expect((payload["data"] as? [String: Any])?["emoji"] as? String == "thumbs-up")
  #expect(payload["clientId"] as? String == "client-1")
  #expect((payload["extras"] as? [String: Any])?["source"] as? String == "ios")
  #expect(payload["idempotencyKey"] as? String == "anno-1")
}

@Test
func annotationEventsPageNextUsesNextCursor() {
  let cursor = Box<String>()
  let page = AnnotationEventsPage(
    items: [],
    direction: "oldest_first",
    limit: 10,
    hasMore: true,
    nextCursor: "anno-cursor-2",
    fetchNext: { next, completion in
      cursor.value = next
      completion(
        .success(
          AnnotationEventsPage(
            items: [],
            direction: "oldest_first",
            limit: 10,
            hasMore: false,
            nextCursor: nil,
            fetchNext: nil
          )
        ))
    }
  )

  page.next { _ in }
  #expect(cursor.value == "anno-cursor-2")
}

@Test
func channelExposesAnnotationInternalEvents() throws {
  let client = try SockudoClient(
    "app-key",
    options: .init(cluster: "local", protocolVersion: 2)
  )
  let channel = client.subscribe("chat")
  let summary = Box<[String: Any]>()
  let raw = Box<[String: Any]>()

  _ = channel.bind("message.summary") { data, _ in
    summary.value = data as? [String: Any]
  }
  _ = channel.bind("annotation.create") { data, _ in
    raw.value = data as? [String: Any]
  }

  channel.handle(
    event: SockudoEvent(
      event: "sockudo_internal:message",
      channel: "chat",
      data: ["action": "message.summary", "messageSerial": "msg-1"],
      userID: nil,
      streamID: nil,
      messageId: nil,
      rawMessage: "",
      sequence: nil,
      conflationKey: nil,
      serial: nil,
      extras: nil
    ))
  channel.handle(
    event: SockudoEvent(
      event: "sockudo_internal:annotation",
      channel: "chat",
      data: ["action": "annotation.create", "messageSerial": "msg-1"],
      userID: nil,
      streamID: nil,
      messageId: nil,
      rawMessage: "",
      sequence: nil,
      conflationKey: nil,
      serial: nil,
      extras: nil
    ))

  #expect(summary.value?["messageSerial"] as? String == "msg-1")
  #expect(raw.value?["action"] as? String == "annotation.create")
}

@Test
func websocketURLIncludesV2FormatQuery() throws {
  let client = try SockudoClient(
    "app-key",
    options: .init(
      cluster: "local",
      protocolVersion: 2,
      forceTLS: false,
      enabledTransports: [.ws],
      wsHost: "ws.example.com",
      wsPort: 6001,
      wssPort: 6002,
      wireFormat: .messagepack
    )
  )

  let url = try client.socketURL(for: .ws)
  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  let queryItems: [URLQueryItem] = components?.queryItems ?? []
  let query = Dictionary(
    uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

  #expect(query["protocol"] == "2")
  #expect(query["format"] == "messagepack")
}

@Test
func websocketURLUsesV1ByDefaultAndOmitsFormatQuery() throws {
  let client = try SockudoClient(
    "app-key",
    options: .init(
      cluster: "local",
      forceTLS: false,
      enabledTransports: [.ws],
      wsHost: "ws.example.com",
      wsPort: 6001,
      wssPort: 6002,
      wireFormat: .messagepack
    )
  )

  let url = try client.socketURL(for: .ws)
  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  let query = Dictionary(
    uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

  #expect(query["protocol"] == "7")
  #expect(query["format"] == nil)
}

@Test
func messagePackRoundTrip() throws {
  let payload = try ProtocolCodec.encodeEnvelope(
    [
      "event": "sockudo:test",
      "channel": "chat:room-1",
      "data": [
        "hello": "world",
        "count": 3,
      ],
      "stream_id": "stream-1",
      "message_id": "msg-1",
      "serial": 7,
      "__delta_seq": 7,
      "__conflation_key": "room",
    ],
    format: .messagepack
  )
  let message: URLSessionWebSocketTask.Message =
    switch payload {
    case .string(let text): .string(text)
    case .data(let data): .data(data)
    }

  let decoded = try ProtocolCodec.decodeEvent(message, format: .messagepack)

  #expect(decoded.event == "sockudo:test")
  #expect(decoded.channel == "chat:room-1")
  #expect((decoded.data as? [String: Any])?["hello"] as? String == "world")
  #expect(((decoded.data as? [String: Any])?["count"] as? NSNumber)?.intValue == 3)
  #expect(decoded.streamID == "stream-1")
  #expect(decoded.messageId == "msg-1")
  #expect(decoded.serial == 7)
  #expect(decoded.sequence == 7)
  #expect(decoded.conflationKey == "room")
}

@Test
func protobufRoundTrip() throws {
  let payload = try ProtocolCodec.encodeEnvelope(
    [
      "event": "sockudo:test",
      "channel": "chat:room-1",
      "data": [
        "hello": "world"
      ],
      "stream_id": "stream-2",
      "message_id": "msg-2",
      "serial": 9,
      "__delta_seq": 11,
      "__conflation_key": "btc",
      "extras": [
        "headers": [
          "region": "eu",
          "ttl": 5,
          "replay": true,
        ],
        "echo": false,
      ],
    ],
    format: .protobuf
  )
  let message: URLSessionWebSocketTask.Message =
    switch payload {
    case .string(let text): .string(text)
    case .data(let data): .data(data)
    }

  let decoded = try ProtocolCodec.decodeEvent(message, format: .protobuf)

  #expect(decoded.event == "sockudo:test")
  #expect(decoded.channel == "chat:room-1")
  #expect((decoded.data as? [String: Any])?["hello"] as? String == "world")
  #expect(decoded.streamID == "stream-2")
  #expect(decoded.messageId == "msg-2")
  #expect(decoded.serial == 9)
  #expect(decoded.sequence == 11)
  #expect(decoded.conflationKey == "btc")
  #expect(decoded.extras?.headers?["region"] == .string("eu"))
  #expect(decoded.extras?.headers?["ttl"] == .int(5))
  #expect(decoded.extras?.headers?["replay"] == .bool(true))
  #expect(decoded.extras?.echo == false)
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
      protocolVersion: 2,
      forceTLS: false,
      enabledTransports: [.ws],
      wsHost: "127.0.0.1",
      wsPort: 6001,
      wssPort: 6001,
      wireFormat: liveWireFormat()
    )
  )

  let channel = client.subscribe("public-updates")
  client.bind("connected") { _, _ in
    connected.value = true
  }
  channel.bind("sockudo:subscription_succeeded") { _, _ in
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
