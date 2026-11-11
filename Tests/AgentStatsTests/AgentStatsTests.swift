import Foundation
import MCP
import Testing

@testable import AgentStats

/// What the SDK posted, captured instead of sent.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    func add(_ data: Data) {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        lock.withLock { bodies.append(body) }
    }

    func take() -> [[String: Any]] {
        lock.withLock {
            defer { bodies = [] }
            return bodies
        }
    }
}

func weatherServer() async -> Server {
    let server = Server(name: "weather", version: "1.0.0", instructions: "Weather by city.", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(name: "get_weather", description: "Current weather for a city", inputSchema: .object(["type": "object"])),
            Tool(name: "get_forecast", description: "Five-day forecast", inputSchema: .object(["type": "object"])),
        ])
    }
    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "get_weather": return .init(content: [.text(text: "Sunny", annotations: nil, _meta: nil)])
        case "get_forecast": return .init(content: [.text(text: "City not found", annotations: nil, _meta: nil)], isError: true)
        default: throw MCPError.invalidParams("Unknown tool \(params.name)")
        }
    }
    return server
}

func connected(_ stats: AgentStats) async throws -> Client {
    let pair = await InMemoryTransport.createConnectedPair()
    let server = await weatherServer()
    try await server.start(transport: stats.wrap(pair.server))
    let client = Client(name: "test-client", version: "2.0")
    _ = try await client.connect(transport: pair.client)
    return client
}

func tracker(_ capture: Capture, sampleRate: Double = 1, captureErrors: Bool = true, errorText: (@Sendable (AgentStats.ErrorInfo) -> String?)? = nil) -> AgentStats {
    let stats = AgentStats(.init(apiKey: "al_srv_test", sampleRate: sampleRate, captureErrors: captureErrors, errorText: errorText, flushInterval: 3600))
    stats.post = { _, key, body in
        #expect(key == "al_srv_test")
        capture.add(body)
        return 202
    }
    return stats
}

@Test func sendsToAgentStats() {
    #expect(AgentStats.ingestURL(nil).absoluteString == "https://agentstats.io/api/ingest/mcp")
    #expect(AgentStats.ingestURL("").absoluteString == "https://agentstats.io/api/ingest/mcp")
    #expect(AgentStats.ingestURL("http://localhost:3000/").absoluteString == "http://localhost:3000/api/ingest/mcp")
}

@Test func recordsEveryRequestWithItsOutcomeAndClient() async throws {
    let capture = Capture()
    let stats = tracker(capture)
    let client = try await connected(stats)
    _ = try await client.listTools()
    _ = try await client.callTool(name: "get_weather", arguments: ["city": "secret-city"])
    _ = try await client.callTool(name: "get_forecast")
    _ = try? await client.callTool(name: "nope")
    await stats.flush()

    let bodies = capture.take()
    #expect(bodies.count == 1)
    let body = try #require(bodies.first)
    #expect(body["serverName"] as? String == "weather")
    let events = try #require(body["events"] as? [[String: Any]])
    #expect(events.map { $0["method"] as? String } == ["initialize", "tools/list", "tools/call", "tools/call", "tools/call"])

    let calls = events.filter { $0["method"] as? String == "tools/call" }
    #expect(calls.map { $0["tool"] as? String } == ["get_weather", "get_forecast", "nope"])
    #expect(calls.map { $0["isError"] as? Bool } == [false, true, true])
    #expect(calls[0]["errorMessage"] is NSNull)
    #expect(calls[1]["errorMessage"] as? String == "City not found")
    #expect((calls[2]["errorMessage"] as? String)?.contains("Unknown tool nope") == true)
    for e in events {
        #expect(e["clientName"] as? String == "test-client")
        #expect(e["clientVersion"] as? String == "2.0")
        #expect(e["sessionId"] as? String == events[0]["sessionId"] as? String)
        #expect((e["durationMs"] as? Double ?? -1) >= 0)
        #expect(e["transport"] is NSNull, "an in-memory transport is neither stdio nor http")
    }

    let catalog = try #require(body["catalog"] as? [String: Any])
    #expect((catalog["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == ["get_weather", "get_forecast"])
    #expect((catalog["serverInfo"] as? [String: Any])?["version"] as? String == "1.0.0")
    #expect(catalog["instructions"] as? String == "Weather by city.")

    let raw = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    #expect(!raw.contains("secret-city"), "tool arguments never leave the server")
    #expect(!raw.contains("Sunny"), "tool results never leave the server")

    // The same tool list again: not resent.
    _ = try await client.listTools()
    await stats.flush()
    let again = capture.take()
    #expect(again.count == 1)
    #expect(again.first?["catalog"] == nil)
}

@Test func captureErrorsOffOrAFunction() async throws {
    func errorMessages(captureErrors: Bool = true, errorText: (@Sendable (AgentStats.ErrorInfo) -> String?)? = nil) async throws -> [Any?] {
        let capture = Capture()
        let stats = tracker(capture, captureErrors: captureErrors, errorText: errorText)
        let client = try await connected(stats)
        _ = try await client.callTool(name: "get_forecast")
        _ = try? await client.callTool(name: "nope")
        await stats.flush()
        let events = capture.take().flatMap { $0["events"] as? [[String: Any]] ?? [] }
        let calls = events.filter { $0["method"] as? String == "tools/call" }
        #expect(calls.map { $0["isError"] as? Bool } == [true, true])
        return calls.map { $0["errorMessage"] }
    }
    #expect(try await errorMessages(captureErrors: false).allSatisfy { $0 is NSNull })
    let kept = try await errorMessages { e in e.code.map { "\(e.tool ?? "?"): JSON-RPC \($0)" } ?? "\(e.tool ?? "?") failed" }
    #expect(kept.map { $0 as? String } == ["get_forecast failed", "nope: JSON-RPC -32602"])
    #expect(try await errorMessages { _ in nil }.allSatisfy { $0 is NSNull })
}

@Test func sampleRateAppliesToToolCallsOnly() async throws {
    let capture = Capture()
    let stats = tracker(capture, sampleRate: 0)
    let client = try await connected(stats)
    _ = try await client.listTools()
    _ = try await client.callTool(name: "get_weather")
    await stats.flush()
    let events = capture.take().flatMap { $0["events"] as? [[String: Any]] ?? [] }
    #expect(events.map { $0["method"] as? String } == ["initialize", "tools/list"])
}

@Test func withoutAKeyTheTransportIsUntouched() async throws {
    let stats = AgentStats(.init(apiKey: ""))
    let pair = await InMemoryTransport.createConnectedPair()
    #expect(!stats.enabled)
    let wrapped = stats.wrap(pair.server)
    #expect(wrapped is InMemoryTransport)
    #expect(!(wrapped is AgentStatsTransport))
}

@Test func overlappingFlushesSendTheToolListOnce() async throws {
    let capture = Capture()
    let stats = AgentStats(.init(apiKey: "al_srv_test", flushInterval: 3600))
    // A slow endpoint, so the second flush starts while the first is still sending.
    stats.post = { _, _, body in
        try? await Task.sleep(for: .milliseconds(200))
        capture.add(body)
        return 202
    }
    let client = try await connected(stats)
    _ = try await client.listTools()
    async let first: Void = stats.flush()
    try await Task.sleep(for: .milliseconds(20))
    _ = try await client.callTool(name: "get_weather")
    async let second: Void = stats.flush()
    _ = await (first, second)
    let bodies = capture.take()
    #expect(bodies.filter { $0["catalog"] != nil }.count == 1)
    #expect(bodies.flatMap { $0["events"] as? [[String: Any]] ?? [] }.count == 3)
}

@Test func aFailedSendRetriesTheToolListWithTheNextBatch() async throws {
    let capture = Capture()
    let stats = AgentStats(.init(apiKey: "al_srv_test", flushInterval: 3600))
    let status = Status()
    stats.post = { _, _, body in
        capture.add(body)
        return status.next()
    }
    let client = try await connected(stats)
    _ = try await client.listTools()
    await stats.flush() // 503: dropped, tool list kept
    _ = try await client.callTool(name: "get_weather")
    await stats.flush()
    let bodies = capture.take()
    #expect(bodies.count == 2)
    #expect(bodies.allSatisfy { $0["catalog"] != nil })
    #expect(bodies[1]["dropped"] as? Int == 2, "the failed batch is counted as dropped")
}

/// 503 the first time, then 202.
final class Status: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int { lock.withLock { calls += 1; return calls == 1 ? 503 : 202 } }
}

@Test func signedInSessionsCarryTheClientAppAndScopesOnly() async throws {
    let capture = Capture()
    let stats = tracker(capture)
    let pair = await InMemoryTransport.createConnectedPair()
    let server = await weatherServer()
    let transport = AgentStatsTransport(pair.server, stats: stats)
    try await server.start(transport: transport)
    let client = Client(name: "test-client", version: "2.0")
    _ = try await client.connect(transport: pair.client)
    _ = try await client.callTool(name: "get_weather")
    // What the HTTP layer knows after verifying the bearer token (the token itself is never needed).
    await transport.signedIn(clientID: "https://claude.ai/oauth/mcp-client-metadata.json", scopes: ["mcp:tools", "mcp:read", "mcp:read"])
    _ = try await client.callTool(name: "get_weather")
    await stats.flush()

    let calls = capture.take().flatMap { $0["events"] as? [[String: Any]] ?? [] }.filter { $0["method"] as? String == "tools/call" }
    #expect(calls.count == 2)
    #expect(calls[0]["auth"] == nil, "before signing in")
    let auth = try #require(calls[1]["auth"] as? [String: Any])
    #expect(auth["method"] as? String == "oauth")
    #expect(auth["client"] as? String == "claude.ai/oauth/mcp-client-metadata.json")
    #expect(auth["scopes"] as? [String] == ["mcp:read", "mcp:tools"])
}

@Test func authSummaryKeepsOnlyPublicClientIDs() {
    #expect(AgentStats.Auth(clientID: "https://claude.ai/oauth/mcp-client-metadata.json", scopes: []).client == "claude.ai/oauth/mcp-client-metadata.json")
    for id in ["b7e1c0de-dcr-client", "https://claude.ai", "https://x.test/c?user=42", "https://u:p@x.test/c", "http://x.test/client.json"] {
        #expect(AgentStats.Auth(clientID: id, scopes: []).client == "registered", "\(id)")
    }
    #expect(AgentStats.Auth(clientID: nil, scopes: []).client == nil)
}
