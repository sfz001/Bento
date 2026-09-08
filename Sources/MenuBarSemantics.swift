enum MenuBarStripState {
    case absent, collapsed, expanded, unavailable
    var allowsCollapsedLayout: Bool { self == .absent || self == .collapsed }
    var readyForDragging: Bool { self == .absent || self == .expanded }
}

import Foundation

enum MenuBarSemantics {
    static func stripState(buttonDescriptions: [String], hasLiveItems: Bool) -> MenuBarStripState {
        if buttonDescriptions.contains("隐藏菜单栏项目") { return .expanded }
        if buttonDescriptions.contains("显示隐藏菜单栏项目") { return .collapsed }
        return hasLiveItems ? .absent : .unavailable
    }

    static func stableModuleName(_ description: String, fallback: String) -> String {
        let name = description.prefix { $0 != "," && $0 != "，" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }
}
