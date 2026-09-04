import Foundation

/// Subsystem that converts live DOM trees into token-efficient semantic structures (Markdown or simplified JSON) optimized for Foundation Models.
public enum SemanticDOMExtractor: Sendable {
    
    /// Returns the JavaScript snippet that extracts a simplified JSON representation of the DOM tree.
    public static func extractionScript(maxDepth: Int = 10) -> String {
        return """
        (function() {
            function simplify(element, depth) {
                if (!element || depth <= 0) return null;
                if (element.nodeType === Node.TEXT_NODE) {
                    let text = element.textContent.trim();
                    return text.length > 0 ? { type: 'text', text: text } : null;
                }
                if (element.nodeType !== Node.ELEMENT_NODE) return null;
                
                const tag = element.tagName.toUpperCase();
                if (['SCRIPT', 'STYLE', 'SVG', 'NOSCRIPT', 'IFRAME'].includes(tag)) {
                    return null;
                }
                
                let node = {
                    tag: tag.toLowerCase()
                };
                
                if (element.id) node.id = element.id;
                if (element.className && typeof element.className === 'string') {
                    node.class = element.className.trim();
                }
                if (element.getAttribute('role')) node.role = element.getAttribute('role');
                if (element.getAttribute('aria-label')) node.ariaLabel = element.getAttribute('aria-label');
                if (element.getAttribute('type')) node.type = element.getAttribute('type');
                if (element.getAttribute('placeholder')) node.placeholder = element.getAttribute('placeholder');
                if (element.getAttribute('value')) node.value = element.getAttribute('value');
                if (element.disabled) node.disabled = true;
                
                let children = [];
                for (let child of element.childNodes) {
                    let simplifiedChild = simplify(child, depth - 1);
                    if (simplifiedChild) {
                        children.push(simplifiedChild);
                    }
                }
                
                if (children.length > 0) {
                    node.children = children;
                }
                
                return node;
            }
            
            try {
                const root = document.body || document.documentElement;
                const result = simplify(root, \(maxDepth));
                return JSON.stringify(result || {});
            } catch (err) {
                return JSON.stringify({ error: err.toString() });
            }
        })()
        """
    }
    
    /// Converts a simplified DOM JSON dictionary into readable semantic Markdown.
    public static func jsonToSemanticMarkdown(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonString
        }
        
        var output = ""
        renderNode(root, into: &output, indentLevel: 0)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func renderNode(_ node: [String: Any], into output: inout String, indentLevel: Int) {
        let indent = String(repeating: "  ", count: indentLevel)
        
        if let type = node["type"] as? String, type == "text", let text = node["text"] as? String {
            output += "\(indent)- \"\(text)\"\n"
            return
        }
        
        guard let tag = node["tag"] as? String else { return }
        var line = "\(indent)<[\(tag)]"
        
        if let id = node["id"] as? String {
            line += " #\(id)"
        }
        if let cls = node["class"] as? String, !cls.isEmpty {
            line += " .\(cls.replacingOccurrences(of: " ", with: "."))"
        }
        if let role = node["role"] as? String {
            line += " role=\"\(role)\""
        }
        if let aria = node["ariaLabel"] as? String {
            line += " aria-label=\"\(aria)\""
        }
        if let value = node["value"] as? String {
            line += " value=\"\(value)\""
        }
        if let placeholder = node["placeholder"] as? String {
            line += " placeholder=\"\(placeholder)\""
        }
        if let disabled = node["disabled"] as? Bool, disabled {
            line += " [disabled]"
        }
        line += ">"
        output += line + "\n"
        
        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                renderNode(child, into: &output, indentLevel: indentLevel + 1)
            }
        }
    }
    
    /// Truncates string content to fit within a designated token budget (approx. 4 chars per token).
    public static func pruneToTokenBudget(_ content: String, maxTokens: Int = 4096) -> String {
        let maxChars = maxTokens * 4
        if content.count <= maxChars {
            return content
        }
        let truncated = String(content.prefix(maxChars))
        return truncated + "\n... [Truncated for token budget of \(maxTokens) tokens]"
    }
}
