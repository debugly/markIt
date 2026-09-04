import Foundation

struct JekyllFrontMatter: Hashable {
    var title: String?
    var date: Date?
    var tags: [String]?
    var categories: [String]?
    var layout: String?
    var rawData: [String: String]
}

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var frontMatter: JekyllFrontMatter?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var displayName: String { frontMatter?.title ?? name }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

enum FileNodeBuilder {
    private static func parseJekyllFrontMatter(from url: URL) -> JekyllFrontMatter? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        
        guard content.hasPrefix("---") else { return nil }
        
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return nil }
        
        var rawData: [String: String] = [:]
        var title: String?
        var date: Date?
        var tags: [String]?
        var categories: [String]?
        var layout: String?
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        
        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            
            rawData[key] = value
            
            switch key {
            case "title":
                title = value
            case "date":
                date = dateFormatter.date(from: value)
            case "tags":
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    tags = value.dropFirst().dropLast()
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
                }
            case "categories":
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    categories = value.dropFirst().dropLast()
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
                }
            case "layout":
                layout = value
            default:
                break
            }
        }
        
        guard !rawData.isEmpty else { return nil }
        
        return JekyllFrontMatter(title: title, date: date, tags: tags, categories: categories, layout: layout, rawData: rawData)
    }

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
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
                }

            return FileNode(url: url, isDirectory: true, children: children)
        }

        let frontMatter = parseJekyllFrontMatter(from: url)
        return FileNode(url: url, isDirectory: false, children: nil, frontMatter: frontMatter)
    }
}
