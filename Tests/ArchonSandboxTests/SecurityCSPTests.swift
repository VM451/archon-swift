import Testing
import Foundation
@testable import ArchonSandbox

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
        let config = SandboxConfiguration(allowNetworkAccess: true, enableWebAssembly: false)
        let policy = SandboxCSPBuilder.buildPolicy(configuration: config)
        
        #expect(policy.contains("connect-src 'self' sandbox: data: blob: https: wss:"))
        #expect(!policy.contains("'wasm-unsafe-eval'"))
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
