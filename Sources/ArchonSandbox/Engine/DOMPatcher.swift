import Foundation

/// High-performance subsystem for applying hot-reloading code updates and differential DOM/CSS patches without full page refreshes.
public enum DOMPatcher: Sendable {
    
    /// Generates a self-executing JavaScript closure that injects or updates dynamic CSS rules.
    public static func generateCSSPatchScript(css: String, styleTagID: String = "sandbox-dynamic-styles") -> String {
        let escapedCSS = escapeForJavaScript(css)
        let escapedStyleTagID = escapeForSingleQuotedJavaScript(styleTagID)
        return """
        (function() {
            try {
                let style = document.getElementById('\(escapedStyleTagID)');
                if (!style) {
                    style = document.createElement('style');
                    style.id = '\(escapedStyleTagID)';
                    document.head.appendChild(style);
                }
                style.textContent = "\(escapedCSS)";
                return JSON.stringify({ success: true, elementCount: document.querySelectorAll('*').length });
            } catch (err) {
                return JSON.stringify({ success: false, error: err.toString(), stack: err.stack });
            }
        })()
        """
    }
    
    /// Generates a self-executing script that mutates a specific DOM subtree target by selector.
    public static func generateSubtreePatchScript(selector: String, newHTML: String, mode: PatchMode = .outerHTML) -> String {
        let escapedHTML = escapeForJavaScript(newHTML)
        let escapedSelector = escapeForSingleQuotedJavaScript(selector)
        let modeAssignment = mode == .outerHTML ? "target.outerHTML" : "target.innerHTML"
        
        return """
        (function() {
            try {
                let target = document.querySelector('\(escapedSelector)');
                if (!target) {
                    return JSON.stringify({ success: false, error: 'Target element not found: \(escapedSelector)' });
                }
                \(modeAssignment) = "\(escapedHTML)";
                return JSON.stringify({ success: true, selector: '\(escapedSelector)' });
            } catch (err) {
                return JSON.stringify({ success: false, error: err.toString(), stack: err.stack });
            }
        })()
        """
    }
    
    /// Generates a script executing agent-provided JavaScript delta with performance timing.
    public static func generateJSPatchScript(jsCode: String) -> String {
        return """
        (function() {
            const startTime = performance.now();
            try {
                const result = (function() {
                    \(jsCode)
                })();
                const duration = performance.now() - startTime;
                let serializedResult = 'undefined';
                if (result !== undefined) {
                    try {
                        serializedResult = JSON.stringify(result);
                    } catch (e) {
                        serializedResult = String(result);
                    }
                }
                return JSON.stringify({
                    success: true,
                    durationMs: duration,
                    result: serializedResult
                });
            } catch (err) {
                const duration = performance.now() - startTime;
                return JSON.stringify({
                    success: false,
                    durationMs: duration,
                    error: err.toString(),
                    stack: err.stack
                });
            }
        })()
        """
    }
    
    public enum PatchMode: Sendable {
        case innerHTML
        case outerHTML
    }
    
    private static func escapeForJavaScript(_ string: String) -> String {
        var escaped = string
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        escaped = escaped.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        escaped = escaped.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return escaped
    }

    private static func escapeForSingleQuotedJavaScript(_ string: String) -> String {
        var escaped = string
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "'", with: "\\'")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        escaped = escaped.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return escaped
    }
}
