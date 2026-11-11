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

    /// Ids of tools/list requests waiting for their answer, when the feedback tool is on.
    private var listIds: Set<String> = []

    func noteList(_ id: String) {
        listIds.insert(id)
        if listIds.count > 1000 { listIds.removeAll() }
    }

    public func send(_ data: Data) async throws {
        stats.record(inbound: false, data: data, session: session, transport: kind)
        // The tool list the client gets has send_feedback added; the catalog (recorded above) keeps the server's own.
        if !listIds.isEmpty, stats.feedbackEnabled, var m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = AgentStatsFeedback.idKey(m["id"]), listIds.remove(id) != nil, var result = m["result"] as? [String: Any],
           var tools = result["tools"] as? [Any], result["nextCursor"] == nil {
            if tools.contains(where: { ($0 as? [String: Any])?["name"] as? String == AgentStatsFeedback.name }) {
                stats.noteServerHasFeedback()
            } else {
                tools.append(AgentStatsFeedback.definition)
                result["tools"] = tools
                m["result"] = result
                if let out = try? JSONSerialization.data(withJSONObject: m) {
                    try await base.send(out)
                    return
                }
            }
        }
        try await base.send(data)
    }

    /// Answers send_feedback itself; true when it did (the server never sees the call).
    func answerFeedback(_ data: Data) async -> Bool {
        guard stats.feedbackEnabled, data.range(of: Data(AgentStatsFeedback.name.utf8)) != nil,
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], m["method"] as? String == "tools/call",
              let id = m["id"], let params = m["params"] as? [String: Any], params["name"] as? String == AgentStatsFeedback.name else { return false }
        let kept = stats.recordFeedback(params["arguments"] as? [String: Any], session: session)
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": [
            "content": [["type": "text", "text": kept ? AgentStatsFeedback.reply : AgentStatsFeedback.emptyReply]],
            "isError": !kept, "resultType": "complete",
        ] as [String: Any]]
        guard let out = try? JSONSerialization.data(withJSONObject: reply) else { return false }
        try? await base.send(out)
        return true
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
                        if stats.feedbackEnabled {
                            if await self.answerFeedback(data) { continue }
                            // Swift's JSONEncoder writes "tools\/list", so look for "list" before parsing.
                            if data.range(of: Data("list".utf8)) != nil, let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               m["method"] as? String == "tools/list", let id = AgentStatsFeedback.idKey(m["id"]) {
                                await self.noteList(id)
                            }
                        }
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

/// The send_feedback tool (https://github.com/getagentstats/spec/blob/main/PROTOCOL.md "Feedback").
enum AgentStatsFeedback {
    static let name = "send_feedback"
    static let reply = "Thanks: your feedback was sent to the developers of this server."
    static let emptyReply = "Nothing was sent: `content` is empty."
    nonisolated(unsafe) static let definition: [String: Any] = [
        "name": name,
        "title": "Send feedback",
        "description": "Send feedback about this server to the people who build it. Use it when a tool failed, returned something wrong or unhelpful, or when you could not do what the user needed with these tools; or when the user asks you to pass something on. Describe what you tried and what you expected in a few sentences. Leave out personal information, secrets and the user's data.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "content": ["type": "string", "description": "What happened and what you expected, in a few sentences."],
                "source": ["type": "string", "enum": ["user", "agent"], "description": "\"user\" when the user asked you to send it, \"agent\" when you are reporting on your own."],
                "tool": ["type": "string", "description": "The tool it is about, if it is about one."],
            ] as [String: Any],
            "required": ["content", "source"],
        ] as [String: Any],
        "annotations": ["title": "Send feedback", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]

    static func idKey(_ id: Any?) -> String? {
        switch id {
        case let s as String: return "s\(s)"
        case let n as NSNumber: return "n\(n)"
        default: return nil
        }
    }
}
