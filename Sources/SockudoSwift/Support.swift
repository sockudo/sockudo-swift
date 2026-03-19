import Foundation

public struct EventMetadata: Sendable, Equatable {
    public let userID: String?

    public init(userID: String? = nil) {
        self.userID = userID
    }
}

public struct EventBindingToken: Hashable, Sendable {
    fileprivate let id: UUID

    fileprivate init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum SockudoError: Error, LocalizedError, Equatable {
    case invalidAppKey
    case invalidOptions(String)
    case unsupportedFeature(String)
    case badEventName(String)
    case badChannelName(String)
    case messageParseError(String)
    case authFailure(statusCode: Int?, message: String)
    case invalidHandshake
    case decryptionFailure(String)
    case deltaFailure(String)
    case invalidURL(String)
    case connectionUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidAppKey:
            return "You must pass your app key when you instantiate SockudoClient."
        case .invalidOptions(let message):
            return message
        case .unsupportedFeature(let message):
            return message
        case .badEventName(let message):
            return message
        case .badChannelName(let message):
            return message
        case .messageParseError(let message):
            return message
        case .authFailure(_, let message):
            return message
        case .invalidHandshake:
            return "Invalid handshake"
        case .decryptionFailure(let message):
            return message
        case .deltaFailure(let message):
            return message
        case .invalidURL(let message):
            return message
        case .connectionUnavailable:
            return "Connection unavailable"
        }
    }
}

enum JSON {
    static func decode(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [])
    }

    static func decodeString(_ string: String) throws -> Any {
        guard let data = string.data(using: .utf8) else {
            throw SockudoError.messageParseError("Unable to decode UTF-8 payload")
        }
        return try decode(data)
    }

    static func encodeString(_ value: Any) throws -> String {
        let data = try encodeData(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SockudoError.messageParseError("Unable to encode UTF-8 payload")
        }
        return string
    }

    static func encodeData(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw SockudoError.messageParseError("Payload is not JSON-serializable")
        }
        return try JSONSerialization.data(withJSONObject: value, options: [])
    }
}

enum QueryString {
    static func encode(_ params: [String: AuthValue]) -> Data {
        let body =
            params
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value.stringValue))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

final class EventDispatcher {
    typealias EventCallback = (Any?, EventMetadata?) -> Void
    typealias GlobalCallback = (String, Any?) -> Void

    private var callbacks: [String: [EventBindingToken: EventCallback]] = [:]
    private var globalCallbacks: [EventBindingToken: GlobalCallback] = [:]
    private let failThrough: ((String, Any?) -> Void)?

    init(failThrough: ((String, Any?) -> Void)? = nil) {
        self.failThrough = failThrough
    }

    @discardableResult
    func bind(_ eventName: String, callback: @escaping EventCallback) -> EventBindingToken {
        let token = EventBindingToken()
        callbacks[eventName, default: [:]][token] = callback
        return token
    }

    @discardableResult
    func bindGlobal(_ callback: @escaping GlobalCallback) -> EventBindingToken {
        let token = EventBindingToken()
        globalCallbacks[token] = callback
        return token
    }

    func unbind(eventName: String? = nil, token: EventBindingToken? = nil) {
        if let eventName {
            guard let token else {
                callbacks[eventName] = nil
                return
            }
            callbacks[eventName]?[token] = nil
            if callbacks[eventName]?.isEmpty == true {
                callbacks[eventName] = nil
            }
            return
        }

        if let token {
            for key in callbacks.keys {
                callbacks[key]?[token] = nil
                if callbacks[key]?.isEmpty == true {
                    callbacks[key] = nil
                }
            }
            globalCallbacks[token] = nil
            return
        }

        callbacks.removeAll()
        globalCallbacks.removeAll()
    }

    func emit(_ eventName: String, data: Any?, metadata: EventMetadata? = nil) {
        for callback in globalCallbacks.values {
            callback(eventName, data)
        }

        if let eventCallbacks = callbacks[eventName], eventCallbacks.isEmpty == false {
            for callback in eventCallbacks.values {
                callback(data, metadata)
            }
        } else {
            failThrough?(eventName, data)
        }
    }
}

public enum AuthValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        }
    }
}

public enum Transport: String, Sendable, CaseIterable, Codable {
    case ws
    case wss
}

public enum ConnectionState: String, Sendable, Equatable {
    case initialized
    case connecting
    case connected
    case disconnected
    case unavailable
    case failed
}

public enum DeltaAlgorithm: String, Sendable, Codable, CaseIterable {
    case fossil
    case xdelta3
}

public struct ChannelDeltaSettings: Sendable, Codable, Equatable {
    public var enabled: Bool?
    public var algorithm: DeltaAlgorithm?

    public init(enabled: Bool? = nil, algorithm: DeltaAlgorithm? = nil) {
        self.enabled = enabled
        self.algorithm = algorithm
    }

    func subscriptionValue() -> Any {
        if enabled == nil, let algorithm {
            return algorithm.rawValue
        }
        if enabled == false, algorithm == nil {
            return false
        }
        if enabled == true, algorithm == nil {
            return true
        }
        var result: [String: Any] = [:]
        if let enabled {
            result["enabled"] = enabled
        }
        if let algorithm {
            result["algorithm"] = algorithm.rawValue
        }
        return result
    }
}

public struct SubscriptionOptions: Sendable, Codable, Equatable {
    public var filter: FilterNode?
    public var delta: ChannelDeltaSettings?

    public init(filter: FilterNode? = nil, delta: ChannelDeltaSettings? = nil) {
        self.filter = filter
        self.delta = delta
    }
}

public struct DeltaOptions {
    public var enabled: Bool?
    public var algorithms: [DeltaAlgorithm]
    public var debug: Bool
    public var onStats: (@Sendable (DeltaStats) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(
        enabled: Bool? = nil,
        algorithms: [DeltaAlgorithm] = [.fossil, .xdelta3],
        debug: Bool = false,
        onStats: (@Sendable (DeltaStats) -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.enabled = enabled
        self.algorithms = algorithms
        self.debug = debug
        self.onStats = onStats
        self.onError = onError
    }
}

public struct ChannelDeltaStats: Sendable, Equatable {
    public let channelName: String
    public let conflationKey: String?
    public let conflationGroupCount: Int
    public let deltaCount: Int
    public let fullMessageCount: Int
    public let totalMessages: Int
}

public struct DeltaStats: Sendable, Equatable {
    public let totalMessages: Int
    public let deltaMessages: Int
    public let fullMessages: Int
    public let totalBytesWithoutCompression: Int
    public let totalBytesWithCompression: Int
    public let bandwidthSaved: Int
    public let bandwidthSavedPercent: Double
    public let errors: Int
    public let channelCount: Int
    public let channels: [ChannelDeltaStats]
}

public struct PresenceMember: Equatable {
    public let id: String
    public let info: AnyHashable?

    public init(id: String, info: AnyHashable?) {
        self.id = id
        self.info = info
    }
}

public struct PusherEvent: @unchecked Sendable {
    let event: String
    let channel: String?
    let data: Any?
    let userID: String?
    let rawMessage: String
    let sequence: Int?
    let conflationKey: String?
}

enum Logger {
    nonisolated(unsafe) static var logToConsole = false
    nonisolated(unsafe) static var customLog: ((String) -> Void)?

    static func debug(_ items: Any...) {
        log(items)
    }

    static func warn(_ items: Any...) {
        log(items)
    }

    static func error(_ items: Any...) {
        log(items)
    }

    private static func log(_ items: [Any]) {
        let message = (["Sockudo"] + items.map { String(describing: $0) }).joined(separator: " : ")
        if let customLog {
            customLog(message)
        } else if logToConsole {
            print(message)
        }
    }
}
