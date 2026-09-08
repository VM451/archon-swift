import Foundation

/// Options configuring page reading and routing behavior.
public struct ReaderOptions: Sendable, Codable, Hashable {
    public var mode: ArchonSearchConfiguration.RoutingMode
    public var timeout: TimeInterval?
    public var minBodyCharacters: Int

    public init(
        mode: ArchonSearchConfiguration.RoutingMode = .automatic,
        timeout: TimeInterval? = nil,
        minBodyCharacters: Int = 400
    ) {
        self.mode = mode
        self.timeout = timeout
        self.minBodyCharacters = minBodyCharacters
    }
}
