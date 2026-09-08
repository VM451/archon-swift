import Foundation
import ArchonCore

extension FrontierQueueActor {
    func isPermitted(_ url: URL, localWorkspaceRoots: [URL]) -> Bool {
        if (try? ArchonNetworkPolicy.publicInternet.validate(url)) != nil {
            return !ArchonNetworkSecurity.isZeroCloudEnabled
        }
        return isAuthorizedLocalFile(url, roots: localWorkspaceRoots)
    }

    func isAuthorizedLocalFile(_ url: URL, roots: [URL]) -> Bool {
        guard url.isFileURL else { return false }
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }

        return roots
            .filter(\.isFileURL)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .contains { root in
                resolvedURL == root || resolvedURL.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
            }
    }
}
