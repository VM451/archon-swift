import Testing
import Foundation
@testable import ArchonAgent

@Suite("MCP (Model Context Protocol) Adapter & Bridge Tests")
struct MCPToolAdapterTests {

    @Test("MCPToolAdapter converts native Tool to MCPToolSchema")
    func mcpToolAdapterConversion() {
        let tool = CalculatorTool()
        let schema = MCPToolAdapter.toMCPSchema(tool: tool)

        #expect(schema.name == "calculator")
        #expect(schema.description.contains("Evaluates"))
        #expect(schema.inputSchema["properties"] != nil)
    }

    @Test("MCPServerBridge lists tools and executes incoming tool calls")
    func mcpServerBridgeExecution() async throws {
        let registry = ToolRegistry()
        registry.register(CalculatorTool())
        registry.register(DeviceInfoTool())

        let serverBridge = MCPServerBridge(registry: registry)
        let toolList = serverBridge.listTools()
        #expect(toolList.count == 2)
        #expect(toolList.contains { $0.name == "calculator" })

        let calcResult = try await serverBridge.handleToolCall(
            name: "calculator",
            argumentsJSON: "{\"expression\": \"15 * 4\"}"
        )
        #expect(calcResult.contains("60"))
    }

    @Test("MCPClientBridge imports external MCP tool into ToolRegistry")
    func mcpClientBridgeImport() async throws {
        let registry = ToolRegistry()
        let clientBridge = MCPClientBridge(registry: registry)

        let externalSchema = MCPToolSchema(
            name: "external_weather",
            description: "Fetches current weather for a city",
            inputSchema: ["type": AnySendable("object")]
        )

        clientBridge.registerMCPTool(schema: externalSchema) { args in
            return "{\"weather\": \"Sunny\", \"temp\": 72}"
        }

        let tool = registry.tool(named: "external_weather")
        #expect(tool != nil)

        let output = try await tool?.call(argumentsJSON: "{}")
        #expect(output?.contains("Sunny") == true)
    }

    @Test("MCP client bridge validates imported tool arguments before invoking the remote closure")
    func mcpClientBridgeValidatesArguments() async throws {
        let registry = ToolRegistry()
        let clientBridge = MCPClientBridge(registry: registry)
        let externalSchema = MCPToolSchema(
            name: "external_weather_required",
            description: "Fetches weather for a city",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "city": AnySendable(["type": AnySendable("string")])
                ]),
                "required": AnySendable([AnySendable("city")])
            ]
        )

        clientBridge.registerMCPTool(schema: externalSchema) { _ in "called" }
        let tool = try #require(registry.tool(named: externalSchema.name))

        do {
            _ = try await tool.call(argumentsJSON: "{}")
            Issue.record("Expected missing MCP arguments to be rejected.")
        } catch let error as ToolValidationError {
            #expect(error.localizedDescription.contains("missing required field"))
        }
    }
}
