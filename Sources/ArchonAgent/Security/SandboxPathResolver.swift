import Foundation

/// Resolves caller-provided paths without allowing them to escape a configured root.
enum SandboxPathResolver {
    static func resolve(_ path: String, relativeTo root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw GraphError.toolExecutionFailed(
                toolName: "fileSystem",
                errorDescription: "Path must be a non-empty relative path."
            )
        }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()

        guard contains(candidate, within: resolvedRoot), contains(parent, within: resolvedRoot) else {
            throw GraphError.toolExecutionFailed(
                toolName: "fileSystem",
                errorDescription: "Path escapes the configured sandbox root."
            )
        }
        return candidate
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let cleanRoot = resolvedRoot.hasSuffix("/") ? String(resolvedRoot.dropLast()) : resolvedRoot
        return resolvedCandidate == cleanRoot || resolvedCandidate.hasPrefix(cleanRoot + "/")
    }
}
