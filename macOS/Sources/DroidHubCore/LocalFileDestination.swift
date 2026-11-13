import Foundation

public enum LocalFileDestination {
    public static func safeName(_ name: String, fallback: String) -> String {
        let leaf = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        return leaf.isEmpty || leaf == "." || leaf == ".." || leaf == "/" ? fallback : leaf
    }

    public static func uniqueURL(named name: String, in directory: URL, reserving reserved: inout Set<String>) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var suffix = 2
        while reserved.contains(key(for: candidate)) || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(stem + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext))
            suffix += 1
        }
        reserved.insert(key(for: candidate))
        return candidate
    }

    public static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
