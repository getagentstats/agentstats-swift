import Foundation
import Testing

/// Runs the example stdio server (Sources/AgentStatsExample) as a real process, drives it over
/// stdin/stdout like an MCP client would, and checks what it posts to a local HTTP endpoint
/// with URLSession: the real send path, the stdio transport tag and the flush at shutdown.
@Test func stdioServerPostsToTheEndpoint() async throws {
    let endpoint = try FakeEndpoint()
    defer { endpoint.stop() }

    let server = Process()
    server.executableURL = try exampleBinary()
    server.environment = [
        "AGENTSTATS_MCP_KEY": "al_srv_test",
        "AGENTSTATS_ENDPOINT": endpoint.url,
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
    ]
    let stdin = Pipe()
    let stdout = Pipe()
    server.standardInput = stdin
    server.standardOutput = stdout
    server.standardError = FileHandle.nullDevice
    try server.run()

    let messages = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.4"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"secret-city"}}}"#,
        #"{"jsonrpc":"2.0","id":"four","method":"tools/call","params":{"name":"get_forecast","arguments":{}}}"#,
    ]
    for m in messages { stdin.fileHandleForWriting.write(Data((m + "\n").utf8)) }

    // Wait for the four responses, then close stdin: the server finishes and flushes.
    var output = Data()
    let deadline = Date().addingTimeInterval(20)
    while output.split(separator: UInt8(ascii: "\n")).count < 4, Date() < deadline {
        let chunk = stdout.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        output.append(chunk)
    }
    #expect(output.split(separator: UInt8(ascii: "\n")).count == 4, "four responses")
    try stdin.fileHandleForWriting.close()
    let exited = Date().addingTimeInterval(10)
    while server.isRunning, Date() < exited { try await Task.sleep(for: .milliseconds(50)) }
    if server.isRunning { server.terminate() }

    let posts = try await endpoint.received(atLeast: 1, within: 5)
    #expect(posts.allSatisfy { $0.auth == "Bearer al_srv_test" && $0.sdk == "swift/0.1.0" })
    let events = posts.flatMap { $0.body["events"] as? [[String: Any]] ?? [] }
    // The server handles requests concurrently, so events come in the order responses went out.
    #expect(events.compactMap { $0["method"] as? String }.sorted() == ["initialize", "tools/call", "tools/call", "tools/list"])
    #expect(events.allSatisfy { $0["transport"] as? String == "stdio" && $0["clientName"] as? String == "claude-code" })
    let forecast = events.first { $0["tool"] as? String == "get_forecast" }
    #expect(forecast?["isError"] as? Bool == true)
    #expect(forecast?["errorMessage"] as? String == "City not found")
    #expect(events.first { $0["tool"] as? String == "get_weather" }?["isError"] as? Bool == false)
    #expect(posts.contains { $0.body["catalog"] != nil })
    #expect(!posts.contains { $0.raw.contains("secret-city") })
}

/// The example binary: the test target depends on it, so it's built next to the test bundle.
/// (Never `swift build` from here: `swift test` holds the build lock.)
func exampleBinary() throws -> URL {
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [".build/out/Products/Debug", ".build/debug", ".build/arm64-apple-macosx/debug", ".build/x86_64-unknown-linux-gnu/debug"]
        .map { packageDir.appendingPathComponent($0).appendingPathComponent("AgentStatsExample") }
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: candidates.map(\.path).joined(separator: ", ")])
    }
    return found
}

/// A local HTTP endpoint (a Python one-liner) that records each POST.
final class FakeEndpoint: @unchecked Sendable {
    struct Post {
        let auth: String
        let sdk: String
        let body: [String: Any]
        let raw: String
    }

    let url: String
    private let process = Process()
    private let out = Pipe()

    init() throws {
        let script = """
        import http.server, json, sys
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"])).decode()
                print(json.dumps({"auth": self.headers["Authorization"], "sdk": self.headers["X-AgentStats-SDK"], "body": body}), flush=True)
                self.send_response(202); self.end_headers(); self.wfile.write(b"{}")
            def log_message(self, *a): pass
        s = http.server.HTTPServer(("127.0.0.1", 0), H)
        print(s.server_port, flush=True)
        s.serve_forever()
        """
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        process.standardOutput = out
        try process.run()
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) { line.append(out.fileHandleForReading.availableData) }
        let port = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        url = "http://127.0.0.1:\(port)/api/ingest/mcp"
    }

    func received(atLeast n: Int, within seconds: Double) async throws -> [Post] {
        var buffer = Data()
        var posts: [Post] = []
        let deadline = Date().addingTimeInterval(seconds)
        let handle = out.fileHandleForReading
        while posts.count < n, Date() < deadline {
            buffer.append(handle.availableData)
            let lines = buffer.split(separator: UInt8(ascii: "\n"))
            posts = lines.compactMap { line in
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let raw = o["body"] as? String else { return nil }
                let body = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                return Post(auth: o["auth"] as? String ?? "", sdk: o["sdk"] as? String ?? "", body: body, raw: raw)
            }
            if posts.count < n { try await Task.sleep(for: .milliseconds(50)) }
        }
        return posts
    }

    func stop() { process.terminate() }
}
