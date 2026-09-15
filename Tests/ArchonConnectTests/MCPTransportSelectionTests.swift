import Testing
import Foundation
@testable import ArchonConnect

@Suite("MCP Transport Selection Tests")
struct MCPTransportSelectionTests {
    @Test("Custom transport remains available with explicit disclosure")
    func customDescriptor() {
        let endpoint = URL(string: "https://mcp.example.test")!
        let descriptor = MCPTransportFactory.descriptor(for: .custom, endpoint: endpoint)
        #expect(descriptor.choice == .custom)
        #expect(descriptor.requiresExplicitToolAuthorization)
        #expect(descriptor.summary.contains("Custom"))
    }

    @Test("Official SDK adapter discloses policy while keeping custom transport")
    func officialDescriptor() {
        let endpoint = URL(string: "https://mcp.example.test")!
        let descriptor = MCPTransportFactory.descriptor(for: .officialSDK, endpoint: endpoint)
        #expect(descriptor.choice == .officialSDK)
        #expect(descriptor.requiresExplicitToolAuthorization)
        #expect(descriptor.summary.contains("Custom transport remains available"))
    }

    @Test("Factory builds the custom transport without the vendor SDK")
    func factoryBuildsCustom() async throws {
        let endpoint = URL(string: "https://mcp.example.test")!
        let transport = MCPTransportFactory.makeCustomTransport(endpoint: endpoint)
        #expect(MCPTransportFactory.descriptor(for: .custom, endpoint: endpoint).endpoint == endpoint)
        await transport.setAuthorizedToolNames([])
        do {
            _ = try await transport.listTools()
            Issue.record("Unconnected transport must fail closed.")
        } catch let error as MCPTransportError {
            #expect(error == .notConnected)
        }
    }
}
