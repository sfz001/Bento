import Darwin
import Foundation

struct ClashCore { let pid: pid_t; let executable: String; let configPath: String; let commandSocket: String? }
struct ClashConfiguration {
    let tunEnabled: Bool, autoRoute: Bool, device: String
    let unixController: String?, tcpController: String?, secret: String?, proxyGroups: [String]
    static func parse(_ yaml: String) -> ClashConfiguration {
        var section = "", values: [String: String] = [:], groups: [String] = []
        for raw in yaml.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !raw.hasPrefix(" ") && !raw.hasPrefix("\t") { section = raw.components(separatedBy: ":").first ?? "" }
            if section == "tun", raw.hasPrefix("  "), !raw.hasPrefix("    ") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = unquote(parts[1].trimmingCharacters(in: .whitespaces)) }
            } else if !raw.hasPrefix(" ") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = unquote(parts[1].trimmingCharacters(in: .whitespaces)) }
            } else if section == "proxy-groups", raw.hasPrefix("  - name:") {
                groups.append(unquote(String(line.dropFirst("- name:".count)).trimmingCharacters(in: .whitespaces)))
            }
        }
        return ClashConfiguration(tunEnabled: values["enable"] == "true", autoRoute: values["auto-route"] == "true",
            device: values["device"] ?? "", unixController: values["external-controller-unix"].flatMap { $0.isEmpty ? nil : $0 },
            tcpController: values["external-controller"].flatMap { $0.isEmpty ? nil : $0 },
            secret: values["secret"].flatMap { $0.isEmpty ? nil : $0 }, proxyGroups: groups)
    }
    private static func unquote(_ value: String) -> String {
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

enum ClashProbeError: LocalizedError {
    case coreNotFound, invalidCore, unreadableConfiguration, tunDisabled, deviceUnavailable, routeUnavailable
    case controllerUnavailable, ruleModeRequired, rulesUnavailable, rulesNotProxy, proxySelectionUnsafe
    var errorDescription: String? {
        switch self {
        case .coreNotFound: return "未找到正在运行的 Clash Verge 核心"
        case .invalidCore: return "Clash 核心身份或参数无法验证"
        case .unreadableConfiguration: return "无法读取本次 Clash 核心运行配置"
        case .tunDisabled: return "Clash 配置未同时启用 TUN 和自动路由"
        case .deviceUnavailable: return "Clash 声明的 TUN 设备没有有效地址"
        case .routeUnavailable: return "默认流量路由未经过 Clash 的 TUN 设备"
        case .controllerUnavailable: return "Clash 控制接口不可用"
        case .ruleModeRequired: return "Clash 未处于可验证的规则模式，Claude 保持阻断"
        case .rulesUnavailable: return "无法验证 Clash 的最终运行规则"
        case .rulesNotProxy: return "Claude 规则未生效或未指向代理组，请检查 Merge 和脚本"
        case .proxySelectionUnsafe: return "Claude 代理组未选中可验证的代理节点（可能选中了 DIRECT）"
        }
    }
}

final class ClashProbe {
    typealias Runner = (String, [String], TimeInterval) -> (status: Int32, output: String)
    private let run: Runner, executablePath: (pid_t) -> String?, readFile: (String) throws -> String
    private let processArguments: (pid_t) -> [String]?
    private let activeInterface: (String) -> Bool
    private let request: (ClashConfiguration, String?, String) throws -> String
    init(run: @escaping Runner = { claudeGuardRunProcess($0, $1, timeout: $2, captureStandardError: $0 == "/sbin/route") },
         executablePath: @escaping (pid_t) -> String? = ClashProbe.kernelExecutablePath,
         processArguments: @escaping (pid_t) -> [String]? = ClashProbe.kernelArguments,
         readFile: @escaping (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
         activeInterface: @escaping (String) -> Bool = ClashProbe.interfaceHasAddress,
         request: @escaping (ClashConfiguration, String?, String) throws -> String = ClashProbe.controllerRequest) {
        self.run = run; self.executablePath = executablePath; self.processArguments = processArguments; self.readFile = readFile
        self.activeInterface = activeInterface; self.request = request
    }
    func core() throws -> ClashCore {
        let result = run("/bin/ps", ["-axo", "pid="], 2)
        guard result.status == 0 else { throw ClashProbeError.invalidCore }
        let names: Set<String> = ["mihomo", "verge-mihomo", "verge-mihomo-alpha"]
        for line in result.output.components(separatedBy: .newlines) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), let path = executablePath(pid),
                  names.contains(URL(fileURLWithPath: path).lastPathComponent) else { continue }
            guard let arguments = processArguments(pid) else { throw ClashProbeError.invalidCore }
            guard let configIndex = arguments.firstIndex(of: "-f"), arguments.indices.contains(configIndex + 1) else { throw ClashProbeError.invalidCore }
            let socketIndex = arguments.firstIndex(of: "-ext-ctl-unix")
            let socket = socketIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            return ClashCore(pid: pid, executable: path, configPath: arguments[configIndex + 1], commandSocket: socket)
        }
        throw ClashProbeError.coreNotFound
    }
    func check() throws {
        let core = try core(), configuration = ClashConfiguration.parse(try readFile(core.configPath))
        guard configuration.tunEnabled && configuration.autoRoute && !configuration.device.isEmpty else { throw ClashProbeError.tunDisabled }
        guard activeInterface(configuration.device) else { throw ClashProbeError.deviceUnavailable }
        let route = run("/sbin/route", ["-n", "get", "-inet", "1.1.1.1"], 2)
        guard route.status == 0, route.output.components(separatedBy: .newlines).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "interface: \(configuration.device)" }) else { throw ClashProbeError.routeUnavailable }
        let ipv6Route = run("/sbin/route", ["-n", "get", "-inet6", "2606:4700:4700::1111"], 2)
        let ipv6Lines = ipv6Route.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // route(8) reports ESRCH with this exact diagnostic, sometimes with exit 0.
        // Only an explicit absent route is safe; permission errors/timeouts are unknown.
        let noIPv6Route = [0, 1].contains(ipv6Route.status)
            && ipv6Lines.contains("route: writing to routing socket: not in table")
        guard noIPv6Route || (ipv6Route.status == 0 && ipv6Lines.contains("interface: \(configuration.device)")) else {
            throw ClashProbeError.routeUnavailable
        }
        let version = try request(configuration, core.commandSocket, "/version")
        guard let data = version.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["meta"] as? Bool == true else { throw ClashProbeError.controllerUnavailable }
        // The listed rules are bypassed in direct/global mode. Read the live
        // controller state because changing modes need not rewrite the YAML.
        let configs = try request(configuration, core.commandSocket, "/configs")
        guard let data = configs.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["mode"] as? String == "rule" else { throw ClashProbeError.ruleModeRequired }
        let rules = try request(configuration, core.commandSocket, "/rules")
        guard Self.rulesRouteToProxy(rules, groups: configuration.proxyGroups) else { throw ClashProbeError.rulesNotProxy }
        let proxies = try request(configuration, core.commandSocket, "/proxies")
        guard let group = Self.proxyGroup(configuration.proxyGroups), Self.selectedProxyIsSafe(proxies, group: group) else {
            throw ClashProbeError.proxySelectionUnsafe
        }
    }
    func preferredProxyGroup() throws -> String {
        let core = try core(), groups = ClashConfiguration.parse(try readFile(core.configPath)).proxyGroups
        guard let group = Self.proxyGroup(groups) else { throw ClashProbeError.rulesNotProxy }
        return group
    }
    static func rulesRouteToProxy(_ json: String, groups: [String]) -> Bool {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = object["rules"] as? [[String: Any]] else { return false }
        let expected = Set(claudeProxyRuleDomains)
        guard let proxy = proxyGroup(groups), rules.count >= expected.count else { return false }
        // Managed prepend-rules must really take precedence over DIRECT/MATCH and scripts.
        let prefix = rules.prefix(expected.count)
        return Set(prefix.compactMap { $0["payload"] as? String }) == expected && prefix.allSatisfy {
            ($0["type"] as? String) == "DomainSuffix" && ($0["proxy"] as? String) == proxy
        }
    }
    private static func proxyGroup(_ groups: [String]) -> String? {
        if groups.contains("PROXY") { return "PROXY" }
        let candidates = groups.filter { $0 != "DIRECT" && $0 != "REJECT" && !$0.isEmpty }
        return candidates.count == 1 ? candidates[0] : nil
    }
    static func selectedProxyIsSafe(_ json: String, group: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = object["proxies"] as? [String: [String: Any]] else { return false }
        let transports: Set<String> = ["shadowsocks", "shadowsocksr", "vmess", "vless", "trojan", "snell", "socks5", "http", "wireguard", "hysteria", "hysteria2", "tuic", "ssh", "anytls", "mieru"]
        func safe(_ name: String, visited: Set<String>) -> Bool {
            guard !visited.contains(name), visited.count < 32,
                  let entry = proxies[name], let type = (entry["type"] as? String)?.lowercased() else { return false }
            if type == "direct" || type == "reject" || type == "rejectdrop" || type == "compatible" || type == "pass" { return false }
            let nextVisited = visited.union([name])
            if ["selector", "urltest", "fallback"].contains(type) {
                guard let selected = entry["now"] as? String, !selected.isEmpty else { return false }
                return safe(selected, visited: nextVisited)
            }
            if ["loadbalance", "relay"].contains(type) {
                guard let members = entry["all"] as? [String], !members.isEmpty else { return false }
                return members.allSatisfy { safe($0, visited: nextVisited) }
            }
            return transports.contains(type)
        }
        return safe(group, visited: [])
    }
    static func kernelArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX], maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(maximum)); size = bytes.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return parseKernelArguments(Data(bytes.prefix(size)))
    }
    static func parseKernelArguments(_ data: Data) -> [String]? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let bytes = [UInt8](data)
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 16384 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        // KERN_PROCARGS2: argc, executable path, NUL padding, then argc NUL-terminated argv strings.
        while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = cursor
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count, let argument = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
            arguments.append(argument); cursor += 1
        }
        return arguments
    }
    private static func kernelExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    private static func interfaceHasAddress(_ name: String) -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard String(cString: item.ifa_name) == name, item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let address = item.ifa_addr else { continue }
            if address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 { return true }
        }
        return false
    }
    private static func controllerRequest(_ configuration: ClashConfiguration, commandSocket: String?, path: String) throws -> String {
        if let socketPath = commandSocket ?? configuration.unixController { return try unixRequest(socketPath: socketPath, path: path) }
        guard let controller = configuration.tcpController, let url = URL(string: "http://\(controller)\(path)") else { throw ClashProbeError.controllerUnavailable }
        var request = URLRequest(url: url, timeoutInterval: 2)
        if let secret = configuration.secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var data: Data?; var status = 0 }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode ?? 0; semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 3) == .success, box.status == 200,
              let data = box.data, let body = String(data: data, encoding: .utf8) else { throw ClashProbeError.controllerUnavailable }
        return body
    }
    private static func unixRequest(socketPath: String, path: String) throws -> String {
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw ClashProbeError.controllerUnavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw ClashProbeError.controllerUnavailable }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in socketPath.withCString {
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, socketPath.utf8.count) } }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw ClashProbeError.controllerUnavailable }
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        guard request.withCString({ send(fd, $0, strlen($0), 0) }) == request.utf8.count else { throw ClashProbeError.controllerUnavailable }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while response.count < 4 * 1024 * 1024 {
            let count = recv(fd, &buffer, buffer.count, 0); if count == 0 { break }
            guard count > 0 else { throw ClashProbeError.controllerUnavailable }
            response.append(buffer, count: count)
        }
        guard let text = String(data: response, encoding: .utf8), let range = text.range(of: "\r\n\r\n"),
              text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200") else { throw ClashProbeError.controllerUnavailable }
        let headers = String(text[..<range.lowerBound]).lowercased(), body = String(text[range.upperBound...])
        return headers.contains("transfer-encoding: chunked") ? try decodeChunked(body) : body
    }
    private static func decodeChunked(_ text: String) throws -> String {
        let bytes = Array(text.utf8); var cursor = 0, decoded = Data()
        while cursor < bytes.count {
            guard let lineEnd = bytes[cursor...].firstIndex(of: 10), lineEnd > cursor,
                  let sizeText = String(data: Data(bytes[cursor..<(lineEnd - 1)]), encoding: .utf8),
                  let size = Int(sizeText.split(separator: ";").first.map(String.init) ?? "", radix: 16) else { throw ClashProbeError.controllerUnavailable }
            cursor = lineEnd + 1; if size == 0 { break }
            guard cursor + size + 1 < bytes.count else { throw ClashProbeError.controllerUnavailable }
            decoded.append(contentsOf: bytes[cursor..<(cursor + size)]); cursor += size + 2
        }
        guard let result = String(data: decoded, encoding: .utf8) else { throw ClashProbeError.controllerUnavailable }
        return result
    }
}
