import Foundation
import Logging
import MCP

/// A transport that records the MCP traffic going through it, then hands every message on
/// unchanged. Wrap the transport you pass to `server.start(transport:)`:
///
///     try await server.start(transport: AgentStatsTransport(StdioTransport()))
///
/// For Streamable HTTP, wrap each session's transport and keep calling `handleRequest` on the
/// original. HTTP request context (headers for auth in handlers) still reaches the server.
public actor AgentStatsTransport: Transport, HTTPContextProviding {
    public let logger: Logger
    private let base: any Transport
    private let stats: AgentStats
    /// One id per connection; with Streamable HTTP each session has its own transport.
    private let session = UUID().uuidString
    private let kind: String?

    public init(_ base: any Transport, stats: AgentStats = .shared) {
        self.base = base
        self.stats = stats
        self.logger = Logger(label: "agentstats.transport")
        // stdio means the server runs on the user's machine (the dashboard shows their country).
        let name = String(describing: type(of: base))
        self.kind = name.contains("Stdio") ? "stdio" : name.contains("HTTPServer") ? "http" : nil
    }

    public func connect() async throws {
        try await base.connect()
    }

    public func disconnect() async {
        await base.disconnect()
    }

    public func send(_ data: Data) async throws {
        stats.record(inbound: false, data: data, session: session, transport: kind)
        try await base.send(data)
    }

    public nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let base = self.base
        let stats = self.stats
        let session = self.session
        let kind = self.kind
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        stats.record(inbound: true, data: data, session: session, transport: kind)
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Mark this session signed in, once your HTTP layer has verified its bearer token: its events
    /// carry the token's client app (its Client ID Metadata Document URL, else "registered") and
    /// scopes. Never pass anything about the user; the token is never needed.
    ///
    ///     await transport.signedIn(clientID: token.clientID, scopes: token.scopes)
    public func signedIn(clientID: String?, scopes: [String]) {
        stats.setAuth(AgentStats.Auth(clientID: clientID, scopes: scopes), session: session)
    }

    public func httpRequestContext(for id: ID) async -> HTTPRequest? {
        await (base as? any HTTPContextProviding)?.httpRequestContext(for: id)
    }
}
