import Testing
import Foundation
@testable import ArchonSandbox
import ArchonCore

@Suite("Sandbox Isolation Boundary Tests")
struct SandboxIsolationTests {
    @Test("Default configuration reports strict local isolation")
    func defaultIsStrictLocal() {
        let config = SandboxConfiguration.default
        #expect(config.isolationLevel == .strictLocal)
        #expect(config.isolationDisclosure.contains("Strict local"))
        #expect(!config.isolationLevel.allowsRemoteContent)
    }

    @Test("Granted permissions widen the disclosed level")
    func permissionsWidenLevel() {
        let config = SandboxConfiguration(allowedPermissions: [.network])
        #expect(config.isolationLevel == .networkRestricted)
        #expect(config.isolationLevel.allowsRemoteContent)
    }

    @Test("Developer flags require acknowledgement")
    func developerRequiresAcknowledgement() {
        #expect(SandboxConfiguration.developer.isolationLevel == .developer)
        #expect(SandboxIsolationLevel.developer.requiresHostAcknowledgement)
        #expect(!SandboxIsolationLevel.strictLocal.requiresHostAcknowledgement)
    }

    @Test("Request gate serves sandbox app paths")
    func gateServesAppPaths() {
        #expect(SandboxRequestGate.workspacePath(scheme: "sandbox", host: "app", path: "/index.html", entryPointPath: "index.html") == "index.html")
        #expect(SandboxRequestGate.workspacePath(scheme: "sandbox", host: nil, path: "/", entryPointPath: "index.html") == "index.html")
        #expect(SandboxRequestGate.workspacePath(scheme: "SANDBOX", host: "APP", path: "/a/b.css", entryPointPath: "index.html") == "a/b.css")
    }

    @Test("Request gate denies traversal and unknown scope")
    func gateDeniesTraversal() {
        #expect(SandboxRequestGate.workspacePath(scheme: "sandbox", host: "app", path: "/../secret", entryPointPath: "index.html") == nil)
        #expect(SandboxRequestGate.workspacePath(scheme: "sandbox", host: "app", path: "/%2e%2e/secret", entryPointPath: "index.html") == nil)
        #expect(SandboxRequestGate.workspacePath(scheme: "https", host: "app", path: "/index.html", entryPointPath: "index.html") == nil)
        #expect(SandboxRequestGate.workspacePath(scheme: "sandbox", host: "evil", path: "/index.html", entryPointPath: "index.html") == nil)
        #expect(SandboxRequestGate.workspacePath(scheme: "sandbox", host: "app", path: String(repeating: "a", count: 600), entryPointPath: "index.html") == nil)
    }
}
