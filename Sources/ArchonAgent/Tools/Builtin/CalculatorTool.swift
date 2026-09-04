import Foundation

/// Built-in tool for evaluating math expressions and calculations deterministically on-device.
public struct CalculatorTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "calculator",
            description: "Evaluates mathematical expressions (e.g., '14 * 25 + sqrt(144)').",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "expression": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Mathematical expression to evaluate")
                    ])
                ]),
                "required": AnySendable([AnySendable("expression")])
            ]
        )
    }

    public init() {}

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exprString = json["expression"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "calculator", errorDescription: "Missing 'expression' argument.")
        }

        let cleanExpr = exprString.trimmingCharacters(in: .whitespacesAndNewlines)
        let expr = NSExpression(format: cleanExpr)
        if let result = expr.toArithmeticExpression().expressionValue(with: nil, context: nil) as? NSNumber {
            return "\(result.stringValue)"
        } else {
            return "\(cleanExpr)"
        }
    }
}

private extension NSExpression {
    func toArithmeticExpression() -> NSExpression {
        self
    }
}
