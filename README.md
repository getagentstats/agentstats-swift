# agentstats-swift

Analytics for Swift MCP servers built on the official [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk): every request from Claude, Cursor, ChatGPT and other clients, with the tool, outcome, latency, client and tool list. Tool arguments and results are never sent.

```swift
// Package.swift
.package(url: "https://github.com/getagentstats/agentstats-swift", from: "0.1.0")
// target dependency: .product(name: "AgentStats", package: "agentstats-swift")
```

```swift
import AgentStats
import MCP

let stats = AgentStats()                       // reads AGENTSTATS_MCP_KEY
try await server.start(transport: stats.wrap(StdioTransport()))
await server.waitUntilCompleted()
await stats.shutdown()                         // sends what's left
```

It wraps the transport, so every request is seen whatever handlers the server registers. For Streamable HTTP, wrap each session's transport (`stats.wrap(StatefulHTTPServerTransport(...))`) and keep calling `handleRequest` on the original; HTTP request context still reaches your handlers.

Recording a message is a timestamp and an append under a short lock; parsing, pairing requests with responses and sending happen on a background task every 2 seconds. Failed sends are dropped, never retried inline, and nothing is thrown into your server. Without a key, `wrap` returns the transport unchanged.

Options (`AgentStats(.init(...))`): `apiKey`, `serverName`, `endpoint`, `sampleRate`, `captureErrors`, `errorText` (a closure taking an `ErrorInfo` and returning the text to keep, or nil), `captureCatalog`, `flushInterval`, `maxBatch`, `maxBuffer`, `debug`. Environment: `AGENTSTATS_MCP_KEY`, `AGENTSTATS_ENDPOINT`, `AGENTSTATS_DISABLED=1`, `AGENTSTATS_DEBUG=1`.

```sh
swift test   # in-memory tests, plus the example stdio server end to end
```
