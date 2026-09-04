import Foundation

/// Injected JavaScript runtime bridge establishing bidirectional communication between native Swift and the WebKit sandbox.
public enum SandboxScriptBridge: Sendable {
    
    public static let handlerName = "sandboxBridge"
    
    /// Generates the bootstrap JavaScript injected into the WKWebView at document start.
    public static func generateBootstrapScript() -> String {
        return """
        (function() {
            if (window.__SwiftSandboxInitialized) return;
            window.__SwiftSandboxInitialized = true;
            
            const originalConsole = {
                log: console.log.bind(console),
                info: console.info.bind(console),
                warn: console.warn.bind(console),
                error: console.error.bind(console),
                debug: console.debug.bind(console)
            };
            
            function postToSwift(payload) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName)) {
                    window.webkit.messageHandlers.\(handlerName).postMessage(payload);
                }
            }
            
            function stringifyArgs(args) {
                return Array.from(args).map(arg => {
                    if (arg === undefined) return 'undefined';
                    if (arg === null) return 'null';
                    if (typeof arg === 'object') {
                        try {
                            return JSON.stringify(arg);
                        } catch (e) {
                            return String(arg);
                        }
                    }
                    return String(arg);
                }).join(' ');
            }
            
            // Console Interception
            console.log = function(...args) {
                originalConsole.log(...args);
                postToSwift({
                    type: 'CONSOLE',
                    level: 'info',
                    message: stringifyArgs(args),
                    timestamp: Date.now()
                });
            };
            
            console.info = function(...args) {
                originalConsole.info(...args);
                postToSwift({
                    type: 'CONSOLE',
                    level: 'info',
                    message: stringifyArgs(args),
                    timestamp: Date.now()
                });
            };
            
            console.warn = function(...args) {
                originalConsole.warn(...args);
                postToSwift({
                    type: 'CONSOLE',
                    level: 'warning',
                    message: stringifyArgs(args),
                    timestamp: Date.now()
                });
            };
            
            console.error = function(...args) {
                originalConsole.error(...args);
                postToSwift({
                    type: 'CONSOLE',
                    level: 'error',
                    message: stringifyArgs(args),
                    timestamp: Date.now()
                });
            };
            
            console.debug = function(...args) {
                originalConsole.debug(...args);
                postToSwift({
                    type: 'CONSOLE',
                    level: 'debug',
                    message: stringifyArgs(args),
                    timestamp: Date.now()
                });
            };
            
            // Global Uncaught Error Interception
            window.addEventListener('error', function(event) {
                postToSwift({
                    type: 'UNCAUGHT_ERROR',
                    message: event.message || 'Unknown runtime script error',
                    filename: event.filename,
                    lineno: event.lineno,
                    colno: event.colno,
                    stack: event.error ? event.error.stack : null,
                    timestamp: Date.now()
                });
            });
            
            window.addEventListener('unhandledrejection', function(event) {
                let reason = event.reason;
                let message = typeof reason === 'object' && reason !== null ? (reason.message || JSON.stringify(reason)) : String(reason);
                let stack = reason && reason.stack ? reason.stack : null;
                postToSwift({
                    type: 'UNCAUGHT_ERROR',
                    message: 'Unhandled Promise Rejection: ' + message,
                    stack: stack,
                    timestamp: Date.now()
                });
            });
            
            // Public SwiftSandboxBridge Object
            window.SwiftSandboxBridge = {
                postMessage: function(message) {
                    if (!message || typeof message !== 'object') return;
                    if (message.type === 'TOOL_CALL') {
                        postToSwift({
                            type: 'TOOL_CALL',
                            id: message.id || (crypto.randomUUID ? crypto.randomUUID() : 'req-' + Date.now()),
                            toolName: message.payload ? message.payload.toolName : (message.toolName || 'Unknown'),
                            arguments: message.payload ? message.payload.arguments : (message.arguments || {}),
                            timestamp: message.timestamp || Date.now()
                        });
                    } else {
                        postToSwift({
                            type: 'CUSTOM_MESSAGE',
                            name: message.name || message.type || 'Custom',
                            payload: typeof message.payload === 'string' ? message.payload : JSON.stringify(message.payload || message),
                            timestamp: Date.now()
                        });
                    }
                },
                registerAgentTool: function(name, schema) {
                    postToSwift({
                        type: 'REGISTER_TOOL',
                        name: name,
                        schema: schema,
                        timestamp: Date.now()
                    });
                }
            };
            
            // Debounced MutationObserver for Live DOM Changes
            let mutationTimeout = null;
            let mutationCount = 0;
            
            function setupMutationObserver() {
                if (!document.body) {
                    setTimeout(setupMutationObserver, 50);
                    return;
                }
                
                const observer = new MutationObserver(function(mutations) {
                    mutationCount += mutations.length;
                    if (mutationTimeout) clearTimeout(mutationTimeout);
                    mutationTimeout = setTimeout(function() {
                        postToSwift({
                            type: 'DOM_MUTATION',
                            summary: 'Observed ' + mutationCount + ' DOM mutations',
                            targetSelector: 'body',
                            timestamp: Date.now()
                        });
                        mutationCount = 0;
                    }, 250);
                });
                
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    characterData: true
                });
            }
            
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupMutationObserver);
            } else {
                setupMutationObserver();
            }
        })();
        """
    }
}
