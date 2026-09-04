@_exported import Foundation
@_exported import SwiftUI

#if canImport(SwiftData)
@_exported import SwiftData
#endif

// Re-export core macros
@freestanding(declaration, names: arbitrary)
public macro Tool(
    description: String = ""
) = #externalMacro(module: "ArchonAgentMacros", type: "ToolMacro")

@attached(member, names: arbitrary)
public macro ArchonGraph() = #externalMacro(module: "ArchonAgentMacros", type: "ArchonGraphMacro")

@attached(peer, names: arbitrary)
public macro AgentNode(
    id: String = "",
    description: String = ""
) = #externalMacro(module: "ArchonAgentMacros", type: "AgentNodeMacro")
