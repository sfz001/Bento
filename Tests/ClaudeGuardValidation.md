# ClaudeGuard 修复与验证记录（2026-10-28）

本次沿用 SMAppService root LaunchDaemon、固定 NSXPC 协议、hosts 和 Clash Merge 架构。没有注销后台项目，没有读取或输出 Clash 控制密钥，没有改动 Claude 的账号、记忆、缓存或历史。

## 已定位的授权错误

旧代码将 `NSXPCConnection.value(forKey: "auditToken")` 直接转换成 `Data`。真实匿名 NSXPC 实验得到：

```text
AUDIT: class=NSConcreteValue asData=false bytes=32 copy=0 validity=0 parse=0 match=0
```

因此失败发生在 token 类型转换，尚未进入 `SecCodeCopyGuestWithAttributes`。实验正确解包 NSValue 后，32 字节 token 创建 SecCode、基本 validity、实验客户端 requirement 解析及匹配均成功。

调试前实机 `codesign -d -r- Bento.app` 与 `ClaudeGuardClient.requirement` 一致：identifier 为 `com.sz.bento`，Apple generic anchor、Developer ID 证书链约束和 Team ID `RV3FMJ29RW` 均保留。

生产代码改为在连接 resume 之前配置 [Foundation 的 setCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))，由系统逐消息执行签名门禁。实际 requirement 从 daemon 自身已验证的签名派生，仅替换准确的 daemon identifier；可写 sidecar 只用于诊断，无法扩大信任。没有改为 PID、进程名或客户端自报 Bundle ID 校验。

## 同时修复的维护问题

- 强持有一秒定时器，防止 start 返回后不再轮询。
- 读取内核 argv，保留配置路径中的空格；不把 ps 输出按空格猜参数。
- Merge 维护在运行态验证之前执行，规则缺失时仍能修复持久配置；重复 on 不反复改 hosts。
- 检查 IPv4 和 IPv6 路由；只有明确不存在 IPv6 路由时才接受无 IPv6 出口，未知错误保持阻断。
- 检查运行模式必须为 rule、五条规则的实际优先级，以及代理组最终选择链，拒绝 DIRECT、循环和未知节点。
- DNS 刷新失败保留重试状态，hosts/Merge 维护失败使 on 返回错误。
- 移除 App 按 build 变化自动 unregister/register；增加 `off --keep-registered` 清理方式。
- 增加固定无参数 `restart`：先阻断、保留持久状态，再退出交由 launchd KeepAlive 重启；不执行调用者提供的命令。回复仅表示接受请求，完成须检查新 PID 和状态。
- CLI 显示未就绪原因并准确返回失败退出码；UI 操作错误不会被下一次状态轮询立即覆盖。

## 已完成验证

- `./build_app.sh --test`：10 组回归，包括真实匿名 NSXPC 正向和不同 ID/证书、缺失/非法 requirement 拒绝测试。
- ClaudeGuard 测试覆盖实际定时器存活、原子 hosts、Merge 幂等、带空格 argv、IPv6 路由、代理选择、模式切换、DNS 重试，以及重启前阻断/并发操作拒绝/重复请求/错误保留。
- Developer ID + Hardened Runtime 构建和 `codesign --verify --strict --deep Bento.app`。
- 已编译同 `com.sz.bento` identifier、ad-hoc 签名的只读实机测试客户端；尚未把服务不可用或旧服务拒绝当作负向验证成功。

匿名 XPC 测试需要系统 CodeSigningHelper 可用。在限制该服务的执行沙箱中出现 4097 属于测试环境失败，不能算签名拒绝验证通过。

## 实机验证尚待管理员重启旧服务

旧 daemon PID 为 81572，仍返回“调用者签名未通过验证”。普通用户 `launchctl kill` 返回 `Not privileged to signal service`；`sudo -n true` 返回需要密码。已请求用户执行一次：

```sh
sudo launchctl kickstart -k system/com.sz.bento.claudeguard
```

这一步保留后台批准。旧版本不支持新增的 XPC restart，无法通过旧的失败授权路径自行升级。加载新版本后，后续重启可使用 `Bento.app/Contents/MacOS/Bento --claude-guard restart`。

以下不能由编译或隔离测试替代，尚未完成：

1. 授权 Bento 对已安装 root daemon 的真实 XPC 成功调用，以及不同签名客户端同时被拒绝。
2. 实机 on/status、hosts 和 Merge 持续幂等维护。
3. TUN 关闭后 api.anthropic.com、platform.claude.com 在系统解析器中同时得到 127.0.0.1 和 ::1；恢复后自动移除。
4. App 退出和真实 daemon 重启后的持续维护。
5. macOS 整机重启未执行。

## 现场基线与恢复

未进行真实 on/off/TUN 切换或注销。保护保持关闭，后台服务保持原注册，TUN 开启，IPv4 路由为 utun1024，IPv6 无外网路由。

hosts 和 Merge 无 Bento 标记，内容与权限基线已保存在 gitignored `.build/claude-guard-validation/baseline.json`。hosts SHA-256 为 `c7dd0e2ed261ce76d76f852596c5b54026b9a894fa481381ffd399b556c0e2da`，Merge SHA-256 为 `20bdcc590225f6847cc87cfadd7fa0e596a545841b17d471f7e52991deaddb86`。后续真实验证结束应使用 `off --keep-registered` 并恢复原 TUN/运行规则，核对内容与权限；不要为测试反复 unregister。
