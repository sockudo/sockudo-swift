import Foundation
import Network

public final class SockudoClient: @unchecked Sendable {
  public struct Options {
    public var cluster: String
    public var protocolVersion: Int
    public var activityTimeout: TimeInterval
    public var forceTLS: Bool?
    public var enabledTransports: [Transport]?
    public var disabledTransports: [Transport]?
    public var wsHost: String?
    public var wsPort: Int
    public var wssPort: Int
    public var wsPath: String
    public var httpHost: String?
    public var httpPort: Int
    public var httpsPort: Int
    public var httpPath: String
    public var pongTimeout: TimeInterval
    public var unavailableTimeout: TimeInterval
    public var enableStats: Bool
    public var statsHost: String
    public var timelineParams: [String: AuthValue]
    public var channelAuthorization: ChannelAuthorizationOptions
    public var userAuthentication: UserAuthenticationOptions
    public var deltaCompression: DeltaOptions?
    public var messageDeduplication: Bool
    public var messageDeduplicationCapacity: Int
    public var connectionRecovery: Bool
    public var echoMessages: Bool
    public var wireFormat: SockudoWireFormat

    public init(
      cluster: String,
      protocolVersion: Int = 7,
      activityTimeout: TimeInterval = 120,
      forceTLS: Bool? = nil,
      enabledTransports: [Transport]? = nil,
      disabledTransports: [Transport]? = nil,
      wsHost: String? = nil,
      wsPort: Int = 80,
      wssPort: Int = 443,
      wsPath: String = "",
      httpHost: String? = nil,
      httpPort: Int = 80,
      httpsPort: Int = 443,
      httpPath: String = "/sockudo",
      pongTimeout: TimeInterval = 30,
      unavailableTimeout: TimeInterval = 10,
      enableStats: Bool = false,
      statsHost: String = "stats.sockudo.com",
      timelineParams: [String: AuthValue] = [:],
      channelAuthorization: ChannelAuthorizationOptions = .init(),
      userAuthentication: UserAuthenticationOptions = .init(),
      deltaCompression: DeltaOptions? = nil,
      messageDeduplication: Bool = true,
      messageDeduplicationCapacity: Int = 1000,
      connectionRecovery: Bool = false,
      echoMessages: Bool = true,
      wireFormat: SockudoWireFormat = .json
    ) {
      self.cluster = cluster
      self.protocolVersion = protocolVersion
      self.activityTimeout = activityTimeout
      self.forceTLS = forceTLS
      self.enabledTransports = enabledTransports
      self.disabledTransports = disabledTransports
      self.wsHost = wsHost
      self.wsPort = wsPort
      self.wssPort = wssPort
      self.wsPath = wsPath
      self.httpHost = httpHost
      self.httpPort = httpPort
      self.httpsPort = httpsPort
      self.httpPath = httpPath
      self.pongTimeout = pongTimeout
      self.unavailableTimeout = unavailableTimeout
      self.enableStats = enableStats
      self.statsHost = statsHost
      self.timelineParams = timelineParams
      self.channelAuthorization = channelAuthorization
      self.userAuthentication = userAuthentication
      self.deltaCompression = deltaCompression
      self.messageDeduplication = messageDeduplication
      self.messageDeduplicationCapacity = messageDeduplicationCapacity
      self.connectionRecovery = connectionRecovery
      self.echoMessages = echoMessages
      self.wireFormat = wireFormat
    }
  }

  public static var logToConsole: Bool {
    get { Logger.logToConsole }
    set { Logger.logToConsole = newValue }
  }

  public static var logHandler: ((String) -> Void)? {
    get { Logger.customLog }
    set { Logger.customLog = newValue }
  }

  public let key: String
  let p: ProtocolPrefix
  var config: ResolvedConfiguration
  public private(set) var connectionState: ConnectionState = .initialized
  public private(set) var socketID: String?
  public let user: UserFacade
  public let watchlist: WatchlistFacade

  let dispatcher = EventDispatcher()
  private var channels: [String: Channel] = [:]
  private let urlSession: URLSession
  private let webSocketDelegate = WebSocketDelegate()
  private var webSocketTask: URLSessionWebSocketTask?
  private var activityTimer: Timer?
  private var unavailableTimer: Timer?
  private var retryTimer: Timer?
  private var timelineSenderTimer: Timer?
  private let reachability = ReachabilityMonitor()
  private var deltaManager: DeltaCompressionManager?
  private var deduplicator: MessageDeduplicator?
  private var channelSerials: [String: Int] = [:]
  private var timeline = Timeline()
  private var currentTransport: Transport?
  private var attemptedFallback = false
  private var manuallyDisconnected = false

  public init(_ key: String, options: Options, urlSession: URLSession? = nil) throws {
    guard key.isEmpty == false else { throw SockudoError.invalidAppKey }
    guard options.cluster.isEmpty == false else {
      throw SockudoError.invalidOptions("Options must provide a cluster")
    }

    self.key = key
    self.p = ProtocolPrefix(version: options.protocolVersion)
    self.config = ResolvedConfiguration(options: options)
    self.user = UserFacade()
    self.watchlist = WatchlistFacade()
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = true
    self.urlSession =
      urlSession
      ?? URLSession(
        configuration: configuration, delegate: webSocketDelegate, delegateQueue: nil)

    self.deltaManager = nil
    if options.messageDeduplication {
      self.deduplicator = MessageDeduplicator(capacity: options.messageDeduplicationCapacity)
    }

    reachability.stateDidChange = { [weak self] isOnline in
      Task { @MainActor in
        guard let self else { return }
        if isOnline {
          if self.connectionState == .connecting || self.connectionState == .unavailable {
            self.scheduleRetry(after: 0)
          }
        } else if self.webSocketTask != nil {
          self.sendPing()
        }
      }
    }

    user.attach(client: self)
    watchlist.attach(client: self)

    if let deltaOptions = options.deltaCompression {
      self.deltaManager = DeltaCompressionManager(options: deltaOptions, prefix: self.p) {
        [weak self] event, data in
        guard let self else { return false }
        return (try? self.sendEvent(name: event, data: data, channel: nil)) ?? false
      }
    }
  }

  deinit {
    reachability.stop()
    urlSession.invalidateAndCancel()
  }

  @discardableResult
  public func on(_ eventName: String, callback: @escaping (Any?, EventMetadata?) -> Void)
    -> EventBindingToken
  {
    dispatcher.bind(eventName, callback: callback)
  }

  @discardableResult
  public func bind(_ eventName: String, callback: @escaping (Any?, EventMetadata?) -> Void)
    -> EventBindingToken
  {
    on(eventName, callback: callback)
  }

  @discardableResult
  public func onGlobal(_ callback: @escaping (String, Any?) -> Void) -> EventBindingToken {
    dispatcher.bindGlobal(callback)
  }

  @discardableResult
  public func bindGlobal(_ callback: @escaping (String, Any?) -> Void) -> EventBindingToken {
    onGlobal(callback)
  }

  public func off(eventName: String? = nil, token: EventBindingToken? = nil) {
    dispatcher.unbind(eventName: eventName, token: token)
  }

  public func unbind(eventName: String? = nil, token: EventBindingToken? = nil) {
    off(eventName: eventName, token: token)
  }

  public func unbindAll() {
    dispatcher.unbind()
  }

  public func channel(named name: String) -> Channel? {
    channels[name]
  }

  public func allChannels() -> [Channel] {
    channels.values.sorted { $0.name < $1.name }
  }

  public func subscribe(_ name: String, options: SubscriptionOptions? = nil) -> Channel {
    let channel = channels[name] ?? makeChannel(named: name)
    channels[name] = channel
    if let options {
      channel.tagsFilter = options.filter
      channel.deltaSettings = options.delta
    }
    channel.subscribeIfPossible()
    return channel
  }

  public func subscribe(_ name: String, filter: FilterNode) -> Channel {
    subscribe(name, options: SubscriptionOptions(filter: filter))
  }

  public func unsubscribe(_ name: String) {
    if let channel = channels[name], channel.subscriptionPending {
      channel.subscriptionCancelled = true
    } else if let channel = channels.removeValue(forKey: name), channel.isSubscribed {
      channel.unsubscribe()
    }
    channelSerials.removeValue(forKey: name)
    deltaManager?.clearChannelState(name)
  }

  public func connect() {
    guard webSocketTask == nil else { return }
    guard transportSequence().isEmpty == false else {
      updateState(.failed)
      return
    }
    manuallyDisconnected = false
    attemptedFallback = false
    updateState(.connecting)
    openWebSocket(using: transportSequence()[0])
    setUnavailableTimer()
    reachability.start()
  }

  public func disconnect() {
    manuallyDisconnected = true
    invalidateTimers()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    currentTransport = nil
    for channel in channels.values {
      channel.disconnect()
    }
    updateState(.disconnected)
  }

  public var shouldUseTLS: Bool {
    config.useTLS
  }

  public func signIn() {
    user.signIn()
  }

  public func getDeltaStats() -> DeltaStats? {
    deltaManager?.getStats()
  }

  public func resetDeltaStats() {
    deltaManager?.resetStats()
  }

  func sendEvent(name: String, data: Any, channel: String?) throws -> Bool {
    guard let webSocketTask else { return false }
    var envelope: [String: Any] = [
      "event": name,
      "data": data,
    ]
    if let channel {
      envelope["channel"] = channel
    }
    let payload = try ProtocolCodec.encodeEnvelope(envelope, format: config.wireFormat)
    let message: URLSessionWebSocketTask.Message =
      switch payload {
      case .string(let text): .string(text)
      case .data(let data): .data(data)
      }
    webSocketTask.send(message) { error in
      if let error {
        Task { @MainActor in
          Logger.error("Send failed", error.localizedDescription)
        }
      }
    }
    return true
  }

  private func subscribeAll() {
    for channel in channels.values {
      channel.subscribeIfPossible()
    }
  }

  private func makeChannel(named name: String) -> Channel {
    if name.hasPrefix("private-encrypted-") {
      return EncryptedChannel(name: name, client: self)
    }
    if name.hasPrefix("private-") {
      return PrivateChannel(name: name, client: self)
    }
    if name.hasPrefix("presence-") {
      return PresenceChannel(name: name, client: self)
    }
    if name.hasPrefix("#") {
      Logger.error("Cannot create a channel with name '\(name)'")
    }
    return Channel(name: name, client: self)
  }

  private func openWebSocket(using transport: Transport) {
    do {
      currentTransport = transport
      let url = try socketURL(for: transport)
      let task = urlSession.webSocketTask(with: url)
      webSocketDelegate.didOpen = { [weak self] in
        self?.readNextMessage()
      }
      webSocketDelegate.didClose = { [weak self] code, reason in
        self?.handleSocketClosed(code: code, reason: reason)
      }
      webSocketTask = task
      task.resume()
    } catch {
      updateState(.failed)
      dispatcher.emit("error", data: error)
    }
  }

  private func readNextMessage() {
    webSocketTask?.receive { [weak self] result in
      guard let self else { return }
      Task { @MainActor in
        switch result {
        case .failure(let error):
          self.dispatcher.emit("error", data: error)
          self.handleSocketClosed(
            code: .abnormalClosure, reason: error.localizedDescription)
        case .success(let message):
          switch message {
          case .string(let text):
            self.handle(rawMessage: .string(text))
          case .data(let data):
            self.handle(rawMessage: .data(data))
          @unknown default:
            break
          }
          self.readNextMessage()
        }
      }
    }
  }

  private func handle(rawMessage: URLSessionWebSocketTask.Message) {
    do {
      let event = try decodeEvent(rawMessage: rawMessage)
      resetActivityTimer()

      if let messageId = event.messageId, let deduplicator {
        if deduplicator.isDuplicate(messageId) {
          Logger.debug("Skipping duplicate message", messageId)
          return
        }
        deduplicator.track(messageId)
      }

      // Track serial per channel for connection recovery
      if config.connectionRecovery, let channelName = event.channel, let serial = event.serial {
        channelSerials[channelName] = serial
      }

      let eventName = event.event
      if eventName == p.event("connection_established") {
        guard let payload = event.data as? [String: Any],
          let socketID = payload["socket_id"] as? String
        else {
          throw SockudoError.invalidHandshake
        }
        self.socketID = socketID
        let negotiatedTimeout =
          (payload["activity_timeout"] as? Double ?? config.activityTimeout) * 1000
        config.activityTimeout =
          min(config.activityTimeout * 1000, negotiatedTimeout) / 1000
        clearUnavailableTimer()
        updateState(.connected, metadata: ["socket_id": socketID])
        subscribeAll()
        if config.connectionRecovery, channelSerials.isEmpty == false {
          let serialsPayload: [String: Any] = ["channel_serials": channelSerials]
          if let jsonData = try? JSON.encodeString(serialsPayload) {
            _ = try? sendEvent(name: p.event("resume"), data: jsonData, channel: nil)
          }
        }
        if config.enableStats {
          startTimelineSender()
        }
        if deltaManager != nil, config.deltaCompressionEnabled {
          deltaManager?.enable()
        }
        user.handleConnected()
      } else if eventName == p.event("error") {
        dispatcher.emit("error", data: event.data)
      } else if eventName == p.event("ping") {
        _ = try? sendEvent(name: p.event("pong"), data: [:], channel: nil)
      } else if eventName == p.event("pong") {
        // no-op
      } else if eventName == p.event("signin_success") {
        user.handleSignInSuccess(event.data)
      } else if eventName == p.internal("watchlist_events") {
        watchlist.handle(event.data)
      } else if eventName == p.event("delta_compression_enabled") {
        deltaManager?.handleEnabled(event.data)
        dispatcher.emit(eventName, data: event.data)
      } else if eventName == p.event("delta_cache_sync") {
        if let channel = event.channel {
          deltaManager?.handleCacheSync(channel: channel, data: event.data)
        }
      } else if eventName == p.event("delta") {
        if let channelName = event.channel,
          let reconstructed = deltaManager?.handleDeltaMessage(
            channel: channelName, data: event.data)
        {
          channels[channelName]?.handle(event: reconstructed)
          dispatcher.emit(reconstructed.event, data: reconstructed.data)
        }
      } else if eventName == p.event("resume_success") {
        Logger.debug("Connection recovery succeeded", event.data as Any)
      } else if eventName == p.event("resume_failed") {
        if let failData = event.data as? [String: Any],
          let failedChannelName = failData["channel"] as? String
        {
          channelSerials.removeValue(forKey: failedChannelName)
          Logger.warn(
            "Connection recovery failed for channel", failedChannelName)
          channels[failedChannelName]?.subscribeIfPossible()
        }
      } else {
        if let channelName = event.channel {
          channels[channelName]?.handle(event: event)
          if let sequence = event.sequence, p.isPlatformEvent(eventName) == false,
            p.isInternalEvent(eventName) == false
          {
            let stripped = stripDeltaMetadata(from: rawMessage)
            deltaManager?.handleFullMessage(
              channel: channelName, rawMessage: stripped, sequence: sequence,
              conflationKey: event.conflationKey)
          }
        }
        if p.isInternalEvent(eventName) == false {
          dispatcher.emit(
            eventName, data: event.data, metadata: EventMetadata(userID: event.userID)
          )
        }
      }
    } catch {
      dispatcher.emit("error", data: error)
    }
  }

  private func decodeEvent(rawMessage: URLSessionWebSocketTask.Message) throws -> SockudoEvent {
    try ProtocolCodec.decodeEvent(rawMessage, format: config.wireFormat)
  }

  private func stripDeltaMetadata(from rawMessage: URLSessionWebSocketTask.Message) -> String {
    let decoded =
      (try? ProtocolCodec.decodeEnvelope(rawMessage, format: config.wireFormat).rawMessage)
      ?? ""
    var result = decoded
    result = result.replacingOccurrences(
      of: #","__delta_seq":\d+"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"__delta_seq":\d+,"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #","__conflation_key":"[^"]*""#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"__conflation_key":"[^"]*","#, with: "", options: .regularExpression)
    return result
  }

  private func handleSocketClosed(code: URLSessionWebSocketTask.CloseCode, reason: String?) {
    invalidateActivityTimer()
    clearUnavailableTimer()
    webSocketTask = nil
    for channel in channels.values {
      channel.disconnect()
    }

    let action = closeAction(for: code)
    switch action {
    case .tlsOnly:
      config.useTLS = true
      scheduleRetry(after: 0)
    case .backoff:
      scheduleRetry(after: 1)
    case .retry:
      scheduleRetry(after: 0)
    case .refused:
      updateState(.disconnected)
    case .none:
      if manuallyDisconnected == false {
        scheduleRetry(after: 1)
      }
    }

    if let reason, reason.isEmpty == false {
      dispatcher.emit("error", data: SockudoError.connectionUnavailable)
      Logger.warn("Socket closed", code.rawValue, reason)
    }
  }

  private func closeAction(for code: URLSessionWebSocketTask.CloseCode) -> CloseAction? {
    let value = Int(code.rawValue)
    if value < 4000 {
      if (1002...1004).contains(value) { return .backoff }
      return nil
    }
    if value == 4000 { return .tlsOnly }
    if value < 4100 { return .refused }
    if value < 4200 { return .backoff }
    if value < 4300 { return .retry }
    return .refused
  }

  func socketURL(for transport: Transport) throws -> URL {
    let scheme = transport == .wss ? "wss" : "ws"
    let host = config.wsHost
    let port = transport == .wss ? config.wssPort : config.wsPort
    let path = "\(config.wsPath)/app/\(key)"
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = port
    components.path = path
    var queryItems: [URLQueryItem] = [
      .init(name: "protocol", value: "\(p.version)"),
      .init(name: "client", value: "swift"),
      .init(name: "version", value: "1.1.0"),
      .init(name: "flash", value: "false"),
    ]
    if config.protocolVersion == 2 {
      queryItems.append(.init(name: "format", value: config.wireFormat.queryValue))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw SockudoError.invalidURL("Unable to build WebSocket URL")
    }
    return url
  }

  private func transportSequence() -> [Transport] {
    var transports = config.useTLS ? [Transport.wss] : [Transport.ws, .wss]
    if let enabled = config.enabledTransports {
      transports = transports.filter { enabled.contains($0) }
    }
    if let disabled = config.disabledTransports {
      transports.removeAll { disabled.contains($0) }
    }
    return transports
  }

  private func sendPing() {
    _ = try? sendEvent(name: p.event("ping"), data: [:], channel: nil)
    invalidateActivityTimer()
    activityTimer = Timer.scheduledTimer(withTimeInterval: config.pongTimeout, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        self?.scheduleRetry(after: 0)
      }
    }
  }

  private func resetActivityTimer() {
    invalidateActivityTimer()
    activityTimer = Timer.scheduledTimer(
      withTimeInterval: config.activityTimeout, repeats: false
    ) { [weak self] _ in
      Task { @MainActor in
        self?.sendPing()
      }
    }
  }

  private func invalidateActivityTimer() {
    activityTimer?.invalidate()
    activityTimer = nil
  }

  private func setUnavailableTimer() {
    clearUnavailableTimer()
    unavailableTimer = Timer.scheduledTimer(
      withTimeInterval: config.unavailableTimeout, repeats: false
    ) { [weak self] _ in
      Task { @MainActor in
        self?.updateState(.unavailable)
      }
    }
  }

  private func clearUnavailableTimer() {
    unavailableTimer?.invalidate()
    unavailableTimer = nil
  }

  private func scheduleRetry(after seconds: TimeInterval) {
    guard manuallyDisconnected == false else { return }
    retryTimer?.invalidate()
    retryTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.updateState(.connecting)
        let transports = self.transportSequence()
        if self.currentTransport == .ws, self.attemptedFallback == false,
          transports.contains(.wss)
        {
          self.attemptedFallback = true
          self.openWebSocket(using: .wss)
        } else {
          self.attemptedFallback = false
          self.openWebSocket(using: transports.first ?? .wss)
        }
        self.setUnavailableTimer()
      }
    }
  }

  private func invalidateTimers() {
    invalidateActivityTimer()
    clearUnavailableTimer()
    retryTimer?.invalidate()
    retryTimer = nil
    timelineSenderTimer?.invalidate()
    timelineSenderTimer = nil
  }

  private func updateState(_ state: ConnectionState, metadata: [String: Any]? = nil) {
    let previous = connectionState
    connectionState = state
    dispatcher.emit(
      "state_change", data: ["previous": previous.rawValue, "current": state.rawValue])
    dispatcher.emit(state.rawValue, data: metadata)
  }

  private func startTimelineSender() {
    timelineSenderTimer?.invalidate()
    timelineSenderTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.sendTimeline()
      }
    }
    sendTimeline()
  }

  private func sendTimeline() {
    guard timeline.isEmpty == false else { return }
    var payload = timeline.payload(key: key, cluster: config.cluster)
    for (key, value) in config.timelineParams {
      payload[key] = value.stringValue
    }
    var components = URLComponents()
    components.scheme = config.useTLS ? "https" : "http"
    components.host = config.statsHost
    components.path = "/timeline/v2/fetch/2"
    components.percentEncodedQuery =
      payload
      .map { key, value in
        "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
      }
      .sorted()
      .joined(separator: "&")
    guard let url = components.url else { return }
    urlSession.dataTask(with: url).resume()
    timeline.markSent()
  }
}

public final class UserFacade: @unchecked Sendable {
  private(set) weak var client: SockudoClient?
  private let dispatcher = EventDispatcher { event, _ in
    Logger.debug("No callbacks on user for \(event)")
  }
  public private(set) var isSignInRequested = false
  public private(set) var userData: [String: Any]?
  public var userID: String? { userData?["id"] as? String }
  fileprivate var serverChannel: Channel?

  init() {}

  func attach(client: SockudoClient) {
    self.client = client
  }

  @discardableResult
  public func on(_ eventName: String, callback: @escaping (Any?, EventMetadata?) -> Void)
    -> EventBindingToken
  {
    dispatcher.bind(eventName, callback: callback)
  }

  public func signIn() {
    isSignInRequested = true
    attemptSignIn()
  }

  func handleConnected() {
    attemptSignIn()
  }

  func handleSignInSuccess(_ data: Any?) {
    guard let payload = data as? [String: Any],
      let userDataString = payload["user_data"] as? String
    else {
      cleanup()
      return
    }
    guard let parsed = try? JSON.decodeString(userDataString) as? [String: Any],
      let id = parsed["id"] as? String, id.isEmpty == false
    else {
      cleanup()
      return
    }
    userData = parsed
    subscribeServerChannel(userID: id)
  }

  private func attemptSignIn() {
    guard isSignInRequested, let client, client.connectionState == .connected,
      let socketID = client.socketID
    else { return }
    client.config.userAuthenticator(UserAuthenticationRequest(socketID: socketID)) {
      [weak self] result in
      Task { @MainActor in
        guard let self, let client = self.client else { return }
        switch result {
        case .failure:
          self.cleanup()
        case .success(let authData):
          _ = try? client.sendEvent(
            name: client.p.event("signin"),
            data: [
              "auth": authData.auth,
              "user_data": authData.userData,
            ], channel: nil)
        }
      }
    }
  }

  private func subscribeServerChannel(userID: String) {
    guard let client else { return }
    let channel = Channel(name: "#server-to-user-\(userID)", client: client)
    channel.onGlobal { [weak self] eventName, data in
      guard let self, let client = self.client else { return }
      guard client.p.isInternalEvent(eventName) == false,
        client.p.isPlatformEvent(eventName) == false
      else { return }
      self.dispatcher.emit(eventName, data: data)
    }
    serverChannel = channel
    channel.subscribeIfPossible()
  }

  private func cleanup() {
    userData = nil
    serverChannel?.unbindAll()
    serverChannel?.disconnect()
    serverChannel = nil
  }
}

public final class WatchlistFacade: @unchecked Sendable {
  private weak var client: SockudoClient?
  private let dispatcher = EventDispatcher { event, _ in
    Logger.debug("No callbacks on watchlist for \(event)")
  }

  init() {}

  func attach(client: SockudoClient) {
    self.client = client
  }

  @discardableResult
  public func on(_ eventName: String, callback: @escaping (Any?, EventMetadata?) -> Void)
    -> EventBindingToken
  {
    dispatcher.bind(eventName, callback: callback)
  }

  func handle(_ data: Any?) {
    guard let payload = data as? [String: Any],
      let events = payload["events"] as? [[String: Any]]
    else { return }
    for event in events {
      if let name = event["name"] as? String {
        dispatcher.emit(name, data: event)
      }
    }
  }
}

extension SockudoClient {
  struct ResolvedConfiguration {
    let cluster: String
    let protocolVersion: Int
    var activityTimeout: TimeInterval
    var useTLS: Bool
    let wireFormat: SockudoWireFormat
    let wsHost: String
    let wsPort: Int
    let wssPort: Int
    let wsPath: String
    let httpHost: String
    let httpPort: Int
    let httpsPort: Int
    let httpPath: String
    let pongTimeout: TimeInterval
    let unavailableTimeout: TimeInterval
    let enableStats: Bool
    let statsHost: String
    let timelineParams: [String: AuthValue]
    let enabledTransports: [Transport]?
    let disabledTransports: [Transport]?
    let channelAuthorizer: ChannelAuthorizationHandler
    let userAuthenticator: UserAuthenticationHandler
    let deltaCompressionEnabled: Bool
    let messageDeduplication: Bool
    let messageDeduplicationCapacity: Int
    let connectionRecovery: Bool

    init(options: Options) {
      cluster = options.cluster
      protocolVersion = options.protocolVersion
      activityTimeout = options.activityTimeout
      useTLS = options.forceTLS == false ? false : true
      wireFormat = options.wireFormat
      wsHost = options.wsHost ?? "ws-\(options.cluster).sockudo.com"
      wsPort = options.wsPort
      wssPort = options.wssPort
      wsPath = options.wsPath
      httpHost = options.httpHost ?? "sockjs-\(options.cluster).sockudo.com"
      httpPort = options.httpPort
      httpsPort = options.httpsPort
      httpPath = options.httpPath
      pongTimeout = options.pongTimeout
      unavailableTimeout = options.unavailableTimeout
      enableStats = options.enableStats
      statsHost = options.statsHost
      timelineParams = options.timelineParams
      enabledTransports = options.enabledTransports
      disabledTransports = options.disabledTransports
      deltaCompressionEnabled = options.deltaCompression?.enabled == true
      messageDeduplication = options.messageDeduplication
      messageDeduplicationCapacity = options.messageDeduplicationCapacity
      connectionRecovery = options.connectionRecovery
      channelAuthorizer =
        options.channelAuthorization.customHandler
        ?? Self.makeChannelAuthorizer(options.channelAuthorization)
      userAuthenticator =
        options.userAuthentication.customHandler
        ?? Self.makeUserAuthenticator(options.userAuthentication)
    }

    private static func makeChannelAuthorizer(_ options: ChannelAuthorizationOptions)
      -> ChannelAuthorizationHandler
    {
      { request, completion in
        Self.performAuthRequest(
          endpoint: options.endpoint,
          headers: options.headers.merging(
            options.headersProvider?() ?? [:], uniquingKeysWith: { _, new in new }),
          params: options.params.merging(
            options.paramsProvider?() ?? [:], uniquingKeysWith: { _, new in new }
          ).merging(
            [
              "socket_id": .string(request.socketID),
              "channel_name": .string(request.channelName),
            ], uniquingKeysWith: { _, new in new }),
          completion: completion
        )
      }
    }

    private static func makeUserAuthenticator(_ options: UserAuthenticationOptions)
      -> UserAuthenticationHandler
    {
      { request, completion in
        Self.performAuthRequest(
          endpoint: options.endpoint,
          headers: options.headers.merging(
            options.headersProvider?() ?? [:], uniquingKeysWith: { _, new in new }),
          params: options.params.merging(
            options.paramsProvider?() ?? [:], uniquingKeysWith: { _, new in new }
          ).merging(
            [
              "socket_id": .string(request.socketID)
            ], uniquingKeysWith: { _, new in new })
        ) { (result: Result<UserAuthenticationData, Error>) in
          completion(result)
        }
      }
    }

    private static func performAuthRequest<T>(
      endpoint: String,
      headers: [String: String],
      params: [String: AuthValue],
      completion: @escaping @Sendable (Result<T, Error>) -> Void
    ) where T: Sendable {
      guard let url = URL(string: endpoint, relativeTo: nil) ?? URL(string: endpoint) else {
        completion(.failure(SockudoError.invalidURL("Invalid auth endpoint \(endpoint)")))
        return
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.httpBody = QueryString.encode(params)
      request.setValue(
        "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
      }
      URLSession.shared.dataTask(with: request) { data, response, error in
        Task { @MainActor in
          if let error {
            completion(.failure(error))
            return
          }
          let status = (response as? HTTPURLResponse)?.statusCode
          guard status == 200, let data else {
            completion(
              .failure(
                SockudoError.authFailure(
                  statusCode: status,
                  message:
                    "Could not get auth info from endpoint, status: \(status ?? -1)"
                )))
            return
          }
          do {
            let object = try JSON.decode(data)
            if T.self == ChannelAuthorizationData.self,
              let dict = object as? [String: Any], let auth = dict["auth"] as? String
            {
              completion(
                .success(
                  ChannelAuthorizationData(
                    auth: auth, channelData: dict["channel_data"] as? String,
                    sharedSecret: dict["shared_secret"] as? String) as! T))
            } else if T.self == UserAuthenticationData.self,
              let dict = object as? [String: Any], let auth = dict["auth"] as? String,
              let userData = dict["user_data"] as? String
            {
              completion(
                .success(
                  UserAuthenticationData(auth: auth, userData: userData) as! T))
            } else {
              completion(
                .failure(
                  SockudoError.authFailure(
                    statusCode: 200,
                    message: "JSON returned from auth endpoint was invalid")))
            }
          } catch {
            completion(.failure(error))
          }
        }
      }.resume()
    }
  }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  var didOpen: (() -> Void)?
  var didClose: ((URLSessionWebSocketTask.CloseCode, String?) -> Void)?

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    didOpen?()
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
    didClose?(closeCode, reasonText)
  }
}

private enum CloseAction {
  case tlsOnly
  case refused
  case backoff
  case retry
}

private final class ReachabilityMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "sockudo.reachability")
  var stateDidChange: (@Sendable (Bool) -> Void)?

  func start() {
    let callback = stateDidChange
    monitor.pathUpdateHandler = { path in
      Task { @MainActor in
        callback?(path.status == .satisfied)
      }
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor.cancel()
  }
}

private struct Timeline {
  private var events: [[String: Any]] = []
  private var sent = 0

  var isEmpty: Bool { events.isEmpty }

  mutating func info(_ event: [String: Any]) {
    events.append(
      event.merging(
        ["timestamp": Int(Date().timeIntervalSince1970 * 1000)],
        uniquingKeysWith: { _, new in new }))
    if events.count > 50 {
      events.removeFirst()
    }
  }

  mutating func markSent() {
    sent += 1
    events.removeAll()
  }

  func payload(key: String, cluster: String) -> [String: String] {
    [
      "session": UUID().uuidString,
      "bundle": String(sent + 1),
      "key": key,
      "lib": "swift",
      "version": "1.1.0",
      "cluster": cluster,
      "timeline": (try? JSON.encodeString(events)) ?? "[]",
    ]
  }
}
