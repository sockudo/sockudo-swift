# SockudoSwift

Official Swift client for Sockudo.

`SockudoSwift` is a Pusher-compatible realtime client for Apple platforms. It preserves the familiar subscribe/bind/channel model while adding Sockudo-native features such as filter-aware subscriptions, delta reconstruction, and encrypted channel handling.

## Platforms

- iOS 13+
- macOS 10.15+
- tvOS 13+
- watchOS 6+
- visionOS 1+

## Features

- Public, private, presence, and encrypted channels
- Channel authorization and user authentication
- Client events on private channels
- User sign-in and watchlist event handling
- Filter-aware subscriptions
- Fossil and Xdelta3/VCDIFF delta reconstruction
- Encrypted channel payload decryption with `swift-sodium`
- Continuity-aware connection recovery and subscribe-time rewind on Protocol V2
- Live integration tests against Sockudo on `127.0.0.1:6001`
- Swift Package Manager distribution with GitHub Actions CI

## Installation

Add the package in Swift Package Manager:

```swift
.package(url: "https://github.com/sockudo/sockudo-swift.git", from: "0.1.0")
```

Then depend on `SockudoSwift`:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SockudoSwift", package: "sockudo-swift"),
    ]
)
```

For local development:

```swift
.package(path: "../sockudo-swift")
```

## Quick Start

```swift
import SockudoSwift

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
channel.bind("price-updated") { data, _ in
    print(data ?? "")
}

client.connect()
```

The default client mode is Protocol V1 compatibility (`protocol=7`). Opt into Protocol V2 explicitly when you want Sockudo-native event prefixes and V2-only features.

```swift
let v2Client = try SockudoClient(
    "app-key",
    options: .init(
        cluster: "local",
        forceTLS: false,
        wsHost: "127.0.0.1",
        wsPort: 6001,
        protocolVersion: 2
    )
)
```

## Advanced Usage

### Channel Authorization

```swift
let client = try SockudoClient(
    "app-key",
    options: .init(
        cluster: "local",
        forceTLS: false,
        wsHost: "127.0.0.1",
        wsPort: 6001,
        channelAuthorization: .init(
            endpoint: "https://api.example.com/pusher/auth"
        )
    )
)
```

### Filters and Delta Compression

```swift
let channel = client.subscribe(
    "price:btc",
    options: .init(
        filter: .eq("market", "spot"),
        delta: .init(enabled: true, algorithm: .xdelta3)
    )
)
```

### Recovery And Rewind

```swift
let client = try SockudoClient(
    "app-key",
    options: .init(
        cluster: "local",
        protocolVersion: 2,
        forceTLS: false,
        wsHost: "127.0.0.1",
        wsPort: 6001,
        connectionRecovery: true
    )
)

let channel = client.subscribe(
    "market:BTC",
    options: .init(rewind: .seconds(30))
)

channel.bind("message") { _, _ in
    print(client.recoveryPosition(for: "market:BTC") as Any)
}

client.bind("sockudo:resume_success") { data, _ in
    print(data as Any)
}

channel.bind("sockudo:rewind_complete") { data, _ in
    print(data as Any)
}
```

### Encrypted Channels

`private-encrypted-*` channels use the `shared_secret` returned by your auth endpoint or custom auth handler. Payload decryption is handled automatically.

## Testing

Standard tests:

```bash
swift test
```

Live integration tests against a local Sockudo server on port `6001`:

```bash
SOCKUDO_LIVE_TESTS=1 swift test
```

The live suite covers:

- public subscribe + publish round-trip
- filter validation and delta option serialization
- encrypted, private, and delta-enabled runtime paths through the client core

## Release Model

Swift packages are distributed by git tag rather than a central package registry by default.

- CI: `.github/workflows/ci.yml`
- Release: tag `v*` and use the repository URL from Swift Package Manager

## Status

The package covers the core Sockudo feature set used by the official JavaScript client, including encrypted channels and both supported delta algorithms.
