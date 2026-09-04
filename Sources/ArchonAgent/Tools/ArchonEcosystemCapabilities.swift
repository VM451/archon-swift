import Foundation

/// Ecosystem capability registrar providing one-line registration of all Archon capabilities:
/// ArchonMemory (Memory & Knowledge), ArchonSandbox (Execution & UI Canvas), ArchonSearch (Web & Local Discovery),
/// and Apple Platform Connectors (Calendar, Reminders, Notes, Contacts, Mail, Files, Maps, SystemControl, Timer).
public extension ToolRegistry {

    /// Registers the standard full suite of Archon Ecosystem capabilities.
    func registerAllEcosystemCapabilities(
        memoryTools: [any Tool] = [MemorySearchTool(), MemoryStoreTool(), CoreMemoryTool()],
        sandboxTools: [any Tool] = [SandboxRenderTool(), SandboxPatchTool(), SandboxInspectDOMTool()],
        searchTools: [any Tool] = [WebSearchTool(), WebContentsTool(), DeepResearchAgentTool()],
        applePlatformTools: [any Tool] = [
            CalendarTool(), RemindersTool(), NotesTool(), ContactsTool(),
            MailTool(), FilesTool(), MapsTool(), SystemControlTool(), TimerTool()
        ],
        utilityTools: [any Tool] = [CalculatorTool(), FileSystemTool(), DeviceInfoTool()]
    ) {
        for tool in memoryTools { register(tool) }
        for tool in sandboxTools { register(tool) }
        for tool in searchTools { register(tool) }
        for tool in applePlatformTools { register(tool) }
        for tool in utilityTools { register(tool) }
    }

    /// Registers ArchonMemory long-term and working memory tools.
    func registerMemoryCapabilities(
        searchTool: any Tool = MemorySearchTool(),
        storeTool: any Tool = MemoryStoreTool(),
        coreMemoryTool: any Tool = CoreMemoryTool()
    ) {
        register(searchTool)
        register(storeTool)
        register(coreMemoryTool)
    }

    /// Registers ArchonSandbox live execution, DOM inspection, and patching tools.
    func registerSandboxCapabilities(
        renderTool: any Tool = SandboxRenderTool(),
        patchTool: any Tool = SandboxPatchTool(),
        inspectDOMTool: any Tool = SandboxInspectDOMTool()
    ) {
        register(renderTool)
        register(patchTool)
        register(inspectDOMTool)
    }

    /// Registers ArchonSearch web discovery, stealth scraping, and deep research tools.
    func registerSearchCapabilities(
        searchTool: any Tool = WebSearchTool(),
        contentsTool: any Tool = WebContentsTool(),
        researchTool: any Tool = DeepResearchAgentTool()
    ) {
        register(searchTool)
        register(contentsTool)
        register(researchTool)
    }

    /// Registers Apple Platform tools (Calendar, Reminders, Notes, Contacts, Mail, Files, Maps, SystemControl, Timer).
    func registerApplePlatformCapabilities(
        services: any ApplePlatformAccessProvider = UnavailableApplePlatformServices()
    ) {
        register(CalendarTool(service: services.calendar))
        register(RemindersTool(service: services.reminders))
        register(NotesTool(service: services.notes))
        register(ContactsTool(service: services.contacts))
        register(MailTool(service: services.mail))
        register(FilesTool(service: services.files))
        register(MapsTool(service: services.maps))
        register(SystemControlTool(service: services.systemControl))
        register(TimerTool(service: services.systemControl))
    }
}
