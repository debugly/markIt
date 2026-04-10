import Foundation

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum FileNodeBuilder {
    static func buildTree(for url: URL) -> FileNode {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            let fm = FileManager.default
            let childrenURLs = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let children = childrenURLs
                .map { buildTree(for: $0) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

            return FileNode(url: url, isDirectory: true, children: children)
        }

        return FileNode(url: url, isDirectory: false, children: nil)
    }
}
