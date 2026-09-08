import Foundation
@main
struct MenuBarSemanticsTests {
    static func main() {
        precondition(MenuBarSemantics.stableModuleName("Wi-Fi, connected, 3 bars", fallback: "WiFi") == "Wi-Fi")
        precondition(MenuBarSemantics.stableModuleName("Wi-Fi，已连接，3 格", fallback: "WiFi") == "Wi-Fi")
        precondition(MenuBarSemantics.stableModuleName("  电池  ，80%", fallback: "Battery") == "电池")
        precondition(MenuBarSemantics.stableModuleName(", connected", fallback: "WiFi") == "WiFi")
        precondition(MenuBarSemantics.stableModuleName("", fallback: "WiFi") == "WiFi")
        print("PASS: stable module labels in Chinese/English and empty-name fallback")
    }
}
