import Testing
import Foundation
@testable import ArchonSandbox
import ArchonCore

@Suite("Security & Content Security Policy (CSP) Tests")
struct SecurityCSPTests {
    
    @Test("Default Content Security Policy generation")
    func testDefaultCSP() {
        let config = SandboxConfiguration(allowNetworkAccess: false, enableWebAssembly: true)
        let policy = SandboxCSPBuilder.buildPolicy(configuration: config)
        
        #expect(policy.contains("default-src 'self' sandbox:"))
        #expect(policy.contains("connect-src 'self' sandbox:"))
        #expect(!policy.contains("https:"))
        #expect(policy.contains("'wasm-unsafe-eval'"))
    }
    
    @Test("Permissive Network Policy generation when enabled")
    func testNetworkEnabledCSP() {
        let config = SandboxConfiguration(
            allowedPermissions: [.network],
            enableWebAssembly: false,
            allowedSchemes: ["sandbox", "data", "blob", "https", "wss"]
        )
        let policy = SandboxCSPBuilder.buildPolicy(configuration: config)
        
        #expect(policy.contains("connect-src 'self' sandbox: data: blob: https:"))
        #expect(!policy.contains(" http:"))
        #expect(policy.contains("wss:"))
        #expect(!policy.contains("'wasm-unsafe-eval'"))
    }

    @Test("Legacy network flag keeps its HTTPS and WebSocket compatibility")
    func testLegacyNetworkCompatibility() {
        let config = SandboxConfiguration(allowNetworkAccess: true, enableWebAssembly: false)
        let policy = SandboxCSPBuilder.buildPolicy(configuration: config)
        #expect(policy.contains("https:"))
        #expect(policy.contains("wss:"))
        #expect(config.allowsURLScheme("https"))
        #expect(config.allowsURLScheme("wss"))
    }

    @Test("Sandbox capabilities default to deny")
    func testDefaultCapabilitiesAreDenied() {
        let config = SandboxConfiguration.default
        #expect(config.allowedPermissions.isEmpty)
        #expect(!config.allows(.network))
        #expect(!config.allows(.storage))
        #expect(!config.allows(.clipboard))
        #expect(!config.allows(.camera))
        #expect(!config.allows(.microphone))
        #expect(!config.allows(.location))
        #expect(!config.allows(.externalURL))
    }

    @Test("Bootstrap bridge installs default-deny guards")
    func testBootstrapCapabilityGuards() {
        let script = SandboxScriptBridge.generateBootstrapScript(configuration: .default)
        #expect(script.contains("Sandbox storage is not enabled."))
        #expect(script.contains("Sandbox clipboard is not enabled."))
        #expect(script.contains("Sandbox camera and microphone access is not enabled."))
        #expect(script.contains("Sandbox location is not enabled."))
        #expect(script.contains("window.open = function() { return null; }"))
    }
    
    @Test("CSP Injection into HTML document head")
    func testCSPInjection() {
        let rawHTML = "<!DOCTYPE html><html><head><title>Test</title></head><body><h1>Hello</h1></body></html>"
        let config = SandboxConfiguration.default
        let injected = SandboxCSPBuilder.injectCSP(into: rawHTML, configuration: config)
        
        #expect(injected.contains("Content-Security-Policy"))
        #expect(injected.contains("<head>"))
    }

    @Test("Existing page CSP cannot weaken the enforced sandbox policy")
    func testExistingCSPIsReplaced() {
        let rawHTML = #"<html><head><meta http-equiv="Content-Security-Policy" content="default-src *"></head><body></body></html>"#
        let injected = SandboxCSPBuilder.injectCSP(into: rawHTML, configuration: .secure)
        #expect(!injected.contains("default-src *"))
        #expect(injected.contains("Content-Security-Policy"))
    }
}
