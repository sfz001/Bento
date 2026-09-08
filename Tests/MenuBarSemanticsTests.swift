import Foundation
@main
struct MenuBarSemanticsTests {
    static func main() {
        precondition(MenuBarSemantics.stableModuleName("Wi-Fi, connected, 3 bars", fallback: "WiFi") == "Wi-Fi")
        precondition(MenuBarSemantics.stableModuleName("Wi-Fi，已连接，3 格", fallback: "WiFi") == "Wi-Fi")
        precondition(MenuBarSemantics.stableModuleName("  电池  ，80%", fallback: "Battery") == "电池")
        precondition(MenuBarSemantics.stableModuleName(", connected", fallback: "WiFi") == "WiFi")
        precondition(MenuBarSemantics.stableModuleName("", fallback: "WiFi") == "WiFi")
        let absent = MenuBarSemantics.stripState(buttonDescriptions: [], hasLiveItems: true)
        precondition(absent == .absent && absent.allowsCollapsedLayout && absent.readyForDragging)
        let unavailable = MenuBarSemantics.stripState(buttonDescriptions: [], hasLiveItems: false)
        precondition(!unavailable.allowsCollapsedLayout && !unavailable.readyForDragging)
        let collapsed = MenuBarSemantics.stripState(buttonDescriptions: ["显示隐藏菜单栏项目"], hasLiveItems: true)
        precondition(collapsed == .collapsed && collapsed.allowsCollapsedLayout && !collapsed.readyForDragging)
        let expanded = MenuBarSemantics.stripState(buttonDescriptions: ["隐藏菜单栏项目"], hasLiveItems: true)
        precondition(expanded == .expanded && !expanded.allowsCollapsedLayout && expanded.readyForDragging)
        print("PASS: stable module labels in Chinese/English and empty-name fallback")
    }
}
