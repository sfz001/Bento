import Foundation

enum MenuBarSemantics {
    static func stableModuleName(_ description: String, fallback: String) -> String {
        let name = description.prefix { $0 != "," && $0 != "，" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }
}
