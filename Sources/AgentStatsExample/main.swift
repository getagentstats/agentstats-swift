// A stdio MCP server with AgentStats wired in: the example in the README, and what
// Tests/AgentStatsTests/EndToEndTests.swift runs as a real process.
import AgentStats
import MCP

let stats = AgentStats(.init(serverName: "weather"))
let server = Server(name: "weather", version: "1.0.0", instructions: "Weather by city.", capabilities: .init(tools: .init()))

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(name: "get_weather", description: "Current weather for a city", inputSchema: .object(["type": "object", "properties": .object(["city": .object(["type": "string"])])])),
        Tool(name: "get_forecast", description: "Five-day forecast", inputSchema: .object(["type": "object"])),
    ])
}
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "get_weather":
        return .init(content: [.text(text: "Sunny in \(params.arguments?["city"]?.stringValue ?? "?")", annotations: nil, _meta: nil)])
    case "get_forecast":
        return .init(content: [.text(text: "City not found", annotations: nil, _meta: nil)], isError: true)
    default:
        throw MCPError.invalidParams("Unknown tool \(params.name)")
    }
}

try await server.start(transport: stats.wrap(StdioTransport()))
await server.waitUntilCompleted()
await stats.shutdown() // sends what's left before the process exits
