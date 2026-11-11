import Foundation
import MCP
import Testing

@testable import AgentStats

@Test func reportsWhatFailedAndResultSize() async throws {
    let capture = Capture()
    let stats = tracker(capture)
    let client = try await connected(stats)
    _ = try await client.listTools()
    _ = try await client.callTool(name: "get_weather", arguments: ["city": "Paris"])
    _ = try await client.callTool(name: "get_forecast")
    _ = try? await client.callTool(name: "nope")
    await stats.flush()

    let events = capture.take().flatMap { ($0["events"] as? [[String: Any]]) ?? [] }
    let calls = events.filter { $0["method"] as? String == "tools/call" }
    #expect(calls[0]["resultChars"] as? Int == 5)
    #expect(calls[0]["errorKind"] == nil)
    #expect(calls[1]["errorKind"] as? String == "tool")
    #expect(calls[1]["resultChars"] == nil)
    #expect(calls[2]["errorKind"] as? String == "protocol")
    #expect(calls[2]["errorCode"] as? Int == -32602)
    #expect(events.first { $0["method"] as? String == "tools/list" }?["resultChars"] == nil)
}

@Test func feedbackToolIsListedAnsweredAndSent() async throws {
    let capture = Capture()
    let stats = AgentStats(.init(apiKey: "al_srv_test", feedbackTool: true, flushInterval: 3600))
    stats.post = { _, _, body in
        capture.add(body)
        return 202
    }
    let client = try await connected(stats)
    let (tools, _) = try await client.listTools()
    #expect(tools.map(\.name) == ["get_weather", "get_forecast", "send_feedback"])
    let (content, isError) = try await client.callTool(name: "send_feedback", arguments: ["content": "forecast says city not found for Paris", "source": "user", "tool": "get_forecast"])
    #expect(isError != true)
    if case let .text(text, _, _) = content.first {
        #expect(text.contains("sent to the developers"))
    } else {
        Issue.record("expected a text reply")
    }
    await stats.flush()

    let bodies = capture.take()
    let feedback = bodies.flatMap { ($0["feedback"] as? [[String: Any]]) ?? [] }
    #expect(feedback.count == 1)
    #expect(feedback.first?["content"] as? String == "forecast says city not found for Paris")
    #expect(feedback.first?["source"] as? String == "user")
    #expect(feedback.first?["tool"] as? String == "get_forecast")
    #expect(feedback.first?["clientName"] as? String == "test-client")
    let catalog = bodies.compactMap { $0["catalog"] as? [String: Any] }.last
    #expect((catalog?["tools"] as? [[String: Any]])?.count == 2)
    let events = bodies.flatMap { ($0["events"] as? [[String: Any]]) ?? [] }
    #expect(!events.contains { $0["tool"] as? String == "send_feedback" })
}
