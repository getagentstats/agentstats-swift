// AgentStats MCP analytics for Swift MCP servers built on the official swift-sdk
// (github.com/modelcontextprotocol/swift-sdk). See https://github.com/getagentstats/spec/blob/main/PROTOCOL.md.
//
//     let stats = AgentStats()                                  // reads AGENTSTATS_MCP_KEY
//     try await server.start(transport: stats.wrap(StdioTransport()))
//
// The SDK wraps the transport, so it sees every request and response whatever handlers the
// server registers. Recording a message is a timestamp and an append under a short lock: the
// bytes aren't even parsed on the request path. A background task parses them, pairs requests
// with responses and ships batches every 2 seconds; on failure a batch is dropped, never
// retried inline, and nothing is thrown into your server. Tool arguments and results are
// never sent: only names, timings, outcomes and error messages.

import Foundation
import MCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class AgentStats: @unchecked Sendable {
    public static let version = "0.1.0"
    static let defaultEndpoint = "https://agentstats.io/api/ingest/mcp"

    /// Options. Unset values fall back to environment variables and defaults.
    /// A failed request, as passed to `Options.errorText`.
    public struct ErrorInfo: Sendable {
        /// The tool for `tools/call`, otherwise nil.
        public let tool: String?
        public let method: String
        /// The JSON-RPC error message, or the first text content of an `isError` result.
        public let message: String
        /// The JSON-RPC error code; nil for `isError` results.
        public let code: Int?
    }

    public struct Options: Sendable {
        /// The MCP server's secret key (`al_srv_…`). Defaults to `AGENTSTATS_MCP_KEY`. Without one the SDK does nothing.
        public var apiKey: String?
        /// Defaults to the name the server reports in `initialize`.
        public var serverName: String?
        /// Defaults to `AGENTSTATS_ENDPOINT`, else the hosted service.
        public var endpoint: String?
        /// Fraction of `tools/call` requests recorded.
        public var sampleRate: Double
        /// Send error messages (first 300 characters).
        public var captureErrors: Bool
        /// Decides per request what is sent of an error's message: return the text to keep, or nil for none.
        /// Runs on the SDK's background task, never on the request path.
        public var errorText: (@Sendable (ErrorInfo) -> String?)?
        /// Send the tool list (names, descriptions, input schemas) when it changes.
        public var captureCatalog: Bool
        public var flushInterval: TimeInterval
        public var maxBatch: Int
        public var maxBuffer: Int
        /// Defaults to `AGENTSTATS_DEBUG=1`. Logs to stderr.
        public var debug: Bool?

        public init(
            apiKey: String? = nil, serverName: String? = nil, endpoint: String? = nil,
            sampleRate: Double = 1, captureErrors: Bool = true, errorText: (@Sendable (ErrorInfo) -> String?)? = nil, captureCatalog: Bool = true,
            flushInterval: TimeInterval = 2, maxBatch: Int = 250, maxBuffer: Int = 10_000, debug: Bool? = nil
        ) {
            self.apiKey = apiKey
            self.serverName = serverName
            self.endpoint = endpoint
            self.sampleRate = sampleRate
            self.captureErrors = captureErrors
            self.errorText = errorText
            self.captureCatalog = captureCatalog
            self.flushInterval = flushInterval
            self.maxBatch = maxBatch
            self.maxBuffer = maxBuffer
            self.debug = debug
        }
    }

    /// A process-wide tracker from the environment, for `AgentStatsTransport(_:)`.
    public static let shared = AgentStats()

    /// One message as it crossed the transport, kept raw until the background task reads it.
    struct Raw: Sendable {
        let inbound: Bool
        let data: Data
        let uptimeNs: UInt64
        let wallMs: Double
        let session: String
        let transport: String?
        var auth: Auth? = nil
    }

    /// What's kept of a validated OAuth access token (https://github.com/getagentstats/spec/blob/main/PROTOCOL.md "Sign-in"): the client app,
    /// by its Client ID Metadata Document URL, and the granted scopes. Never the token or the user.
    public struct Auth: Sendable, Equatable {
        public let client: String?
        public let scopes: [String]

        /// The client app by its Client ID Metadata Document URL (https, with a path, no credentials
        /// or query), else "registered" (Dynamic Client Registration ids are random per
        /// installation), and the scopes: de-duplicated, sorted, at most 20 of at most 80 chars.
        public init(clientID: String?, scopes: [String]) {
            if let id = clientID, !id.isEmpty {
                if let u = URLComponents(string: id), u.scheme == "https", let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.query == nil, u.path.count > 1 {
                    let port = u.port.map { ":\($0)" } ?? ""
                    client = String("\(host)\(port)\(u.path)".prefix(200))
                } else {
                    client = "registered"
                }
            } else {
                client = nil
            }
            self.scopes = Array(Set(scopes.filter { !$0.isEmpty && $0.count <= 80 })).sorted().prefix(20).map { $0 }
        }

        var json: [String: Any] { ["method": "oauth", "client": client ?? NSNull(), "scopes": scopes] }
    }

    private var auths: [String: Auth] = [:]

    /// Mark a session signed in: its events carry the token's client app and scopes from now on.
    func setAuth(_ auth: Auth?, session: String) {
        lock.lock()
        auths[session] = auth
        if auths.count > 5000 { auths.removeAll() }
        lock.unlock()
    }

    public let enabled: Bool
    let options: Options
    let apiKey: String
    let endpoint: URL
    let debug: Bool
    /// Posts a body and returns the HTTP status; replaced in tests.
    var post: @Sendable (URL, String, Data) async -> Int

    private let lock = NSLock()
    private var raw: [Raw] = []
    private var droppedRaw = 0
    private var worker: Task<Void, Never>?
    private var kicked = false
    private let processor: Processor

    public init(_ options: Options = Options()) {
        let env = ProcessInfo.processInfo.environment
        let key = options.apiKey ?? env["AGENTSTATS_MCP_KEY"] ?? ""
        self.options = options
        self.apiKey = key
        self.endpoint = URL(string: options.endpoint ?? env["AGENTSTATS_ENDPOINT"] ?? Self.defaultEndpoint) ?? URL(string: Self.defaultEndpoint)!
        self.debug = options.debug ?? (env["AGENTSTATS_DEBUG"] == "1")
        self.enabled = !key.isEmpty && env["AGENTSTATS_DISABLED"] != "1"
        self.post = Self.httpPost
        self.processor = Processor(options: options)
        if !enabled { log("no API key, analytics disabled") }
    }

    /// Wraps a transport so its traffic is recorded. Without a key it returns the transport unchanged.
    public func wrap(_ transport: any Transport) -> any Transport {
        enabled ? AgentStatsTransport(transport, stats: self) : transport
    }

    // MARK: Request path

    /// A timestamp and an append under a short lock. Called by AgentStatsTransport for every message.
    func record(inbound: Bool, data: Data, session: String, transport: String?) {
        guard enabled else { return }
        var r = Raw(inbound: inbound, data: data, uptimeNs: DispatchTime.now().uptimeNanoseconds, wallMs: Date().timeIntervalSince1970 * 1000, session: session, transport: transport)
        // A request and its response are two messages, so the buffer holds twice the events.
        let cap = options.maxBuffer * 2
        var startWorker = false
        var kick = false
        lock.lock()
        r.auth = auths[session]
        raw.append(r)
        if raw.count > cap {
            raw.removeFirst(raw.count - cap)
            droppedRaw += 1
        }
        if worker == nil { startWorker = true }
        if raw.count >= options.maxBatch * 2 && !kicked {
            kicked = true
            kick = true
        }
        lock.unlock()
        if startWorker { startLoop() }
        if kick { Task.detached(priority: .utility) { [self] in await flush() } }
    }

    // MARK: Background

    private func startLoop() {
        lock.lock()
        defer { lock.unlock() }
        guard worker == nil else { return }
        let interval = UInt64(max(0.05, options.flushInterval) * 1_000_000_000)
        // A detached task never keeps the process alive.
        worker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self?.flush()
            }
        }
    }

    /// Parses what was recorded and sends it now. Call before a short-lived process exits.
    public func flush() async {
        guard enabled else { return }
        let (batch, dropped) = lock.withLock {
            let taken = (raw, droppedRaw)
            raw.removeAll(keepingCapacity: true)
            droppedRaw = 0
            kicked = false
            return taken
        }
        let sends = await processor.ingest(batch, droppedMessages: dropped)
        for s in sends {
            let status = await post(endpoint, apiKey, s.body)
            log("sent \(s.events) events\(s.catalogSig != nil ? " + catalog" : "") -> \(status)")
            if (200..<300).contains(status) {
                if let sig = s.catalogSig { await processor.catalogSent(sig) }
            } else {
                await processor.failed(events: s.events, catalogSig: s.catalogSig)
            }
        }
    }

    /// Flushes and stops the background task.
    public func shutdown() async {
        await flush()
        lock.withLock {
            worker?.cancel()
            worker = nil
        }
    }

    static func httpPost(_ url: URL, _ key: String, _ body: Data) async -> Int {
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("swift/\(version)", forHTTPHeaderField: "X-AgentStats-SDK")
        do {
            let (_, res) = try await URLSession.shared.data(for: req)
            return (res as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }

    func log(_ message: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(Data("[agentstats] \(message())\n".utf8)) }
    }
}

/// Pairs requests with responses and builds what to send. Only the background task touches it.
actor Processor {
    static let tracked: Set<String> = ["tools/call", "tools/list", "initialize", "server/discover", "resources/read", "resources/list", "prompts/get", "prompts/list"]

    struct Pending {
        let method: String
        let tool: String?
        let uptimeNs: UInt64
        let clientName: String?
        let clientVersion: String?
        let sampled: Bool
        let paged: Bool
    }

    struct Send: Sendable {
        let body: Data
        let events: Int
        let catalogSig: String?
    }

    let options: Options
    typealias Options = AgentStats.Options
    var pending: [String: Pending] = [:]
    var clients: [String: (name: String?, version: String?)] = [:]
    var events: [[String: Any]] = []
    var dropped = 0
    var serverInfo: [String: Any]?
    var instructions: String?
    var catalog: (sig: String, tools: [[String: Any]])?
    /// Attached to a request still on its way; another flush mustn't send it too.
    var inFlight: (sig: String, tools: [[String: Any]])?
    var sentSig: String?

    init(options: Options) {
        self.options = options
    }

    func ingest(_ batch: [AgentStats.Raw], droppedMessages: Int) -> [Send] {
        dropped += droppedMessages
        for r in batch {
            guard let obj = try? JSONSerialization.jsonObject(with: r.data) else { continue }
            let messages = (obj as? [Any]) ?? [obj]
            for case let m as [String: Any] in messages {
                if r.inbound { request(m, r) } else { response(m, r) }
            }
        }
        // Requests that never got an answer (a crashed handler, a dropped connection) don't pile up.
        if pending.count > 10_000 { pending.removeAll() }
        if events.count > options.maxBuffer {
            dropped += events.count - options.maxBuffer
            events.removeFirst(events.count - options.maxBuffer)
        }
        return takeSends()
    }

    private func key(_ session: String, _ id: Any?) -> String? {
        switch id {
        case let s as String: return "\(session)|s\(s)"
        case let n as NSNumber: return "\(session)|n\(n)"
        default: return nil
        }
    }

    private func request(_ m: [String: Any], _ r: AgentStats.Raw) {
        guard let method = m["method"] as? String, let k = key(r.session, m["id"]) else { return }
        let params = m["params"] as? [String: Any]
        if method == "initialize", let info = params?["clientInfo"] as? [String: Any] {
            clients[r.session] = (info["name"] as? String, info["version"] as? String)
        }
        guard Self.tracked.contains(method) else { return }
        // Protocol 2026-07-28: client info on each request.
        let meta = (params?["_meta"] as? [String: Any])?["io.modelcontextprotocol/clientInfo"] as? [String: Any]
        let client = clients[r.session]
        let sampled = method != "tools/call" || options.sampleRate >= 1 || Double.random(in: 0..<1) < options.sampleRate
        pending[k] = Pending(
            method: method,
            tool: method == "tools/call" ? params?["name"] as? String : nil,
            uptimeNs: r.uptimeNs,
            clientName: meta?["name"] as? String ?? client?.name,
            clientVersion: meta?["version"] as? String ?? client?.version,
            sampled: sampled,
            paged: params?["cursor"] != nil
        )
    }

    private func response(_ m: [String: Any], _ r: AgentStats.Raw) {
        guard let k = key(r.session, m["id"]), let p = pending.removeValue(forKey: k) else { return }
        let error = m["error"] as? [String: Any]
        let result = m["result"] as? [String: Any]
        let isError = error != nil || (result?["isError"] as? Bool) == true
        if p.method == "initialize", let result {
            serverInfo = result["serverInfo"] as? [String: Any]
            instructions = result["instructions"] as? String
        }
        if p.method == "tools/list", options.captureCatalog, !p.paged, result?["nextCursor"] == nil, let tools = result?["tools"] as? [[String: Any]] {
            noteCatalog(tools)
        }
        guard p.sampled else { return }
        var message: String?
        if isError && options.captureErrors {
            message = error?["message"] as? String
                ?? ((result?["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String)
            if let text = message, let errorText = options.errorText {
                message = errorText(AgentStats.ErrorInfo(tool: p.tool, method: p.method, message: text, code: error?["code"] as? Int))
                if message?.isEmpty == true { message = nil }
            }
            message = message.map { String($0.prefix(300)) }
        }
        let duration = Double(r.uptimeNs &- p.uptimeNs) / 1_000_000
        events.append([
            "ts": Int64(r.wallMs),
            "method": p.method,
            "tool": p.tool ?? NSNull(),
            "durationMs": max(0, duration),
            "isError": isError,
            "errorMessage": message ?? NSNull(),
            "clientName": p.clientName ?? NSNull(),
            "clientVersion": p.clientVersion ?? NSNull(),
            "sessionId": r.session,
            "transport": r.transport ?? NSNull(),
        ].merging(r.auth.map { ["auth": $0.json] } ?? [:]) { a, _ in a })
    }

    /// A cheap signature: tool count, then each name and description length.
    private func noteCatalog(_ tools: [[String: Any]]) {
        let sig = "\(tools.count)|" + tools.map { "\($0["name"] as? String ?? ""):\(($0["description"] as? String)?.count ?? 0)" }.joined(separator: ",")
        guard sig != sentSig, sig != inFlight?.sig else { return }
        catalog = (sig, tools.map { t in
            var out: [String: Any] = ["name": t["name"] ?? ""]
            if let d = t["description"] { out["description"] = d }
            if let s = t["inputSchema"] { out["inputSchema"] = s }
            return out
        })
    }

    private func takeSends() -> [Send] {
        var sends: [Send] = []
        var pendingCatalog = catalog
        if let c = catalog {
            inFlight = c
            catalog = nil
        }
        while !events.isEmpty || pendingCatalog != nil {
            let chunk = Array(events.prefix(1000))
            events.removeFirst(chunk.count)
            let name = options.serverName ?? (serverInfo?["name"] as? String)
            var body: [String: Any] = ["serverName": name.map { $0 as Any } ?? NSNull(), "events": chunk, "dropped": dropped]
            dropped = 0
            var sig: String?
            if let c = pendingCatalog {
                var cat: [String: Any] = ["tools": c.tools]
                if let serverInfo { cat["serverInfo"] = ["name": serverInfo["name"] ?? NSNull(), "version": serverInfo["version"] ?? NSNull()] }
                if let instructions { cat["instructions"] = instructions }
                body["catalog"] = cat
                sig = c.sig
                pendingCatalog = nil
            }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
            sends.append(Send(body: data, events: chunk.count, catalogSig: sig))
        }
        return sends
    }

    func catalogSent(_ sig: String) {
        sentSig = sig
        if inFlight?.sig == sig { inFlight = nil }
    }

    /// A failed send is dropped, never retried; the catalog goes again with the next batch.
    func failed(events count: Int, catalogSig: String?) {
        dropped += count
        if let sig = catalogSig, inFlight?.sig == sig {
            if catalog == nil { catalog = inFlight }
            inFlight = nil
        }
    }
}
