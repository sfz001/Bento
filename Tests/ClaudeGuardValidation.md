# ClaudeGuard 与滚动权限实机验证（2026-10-28）

最终状态：Bento 主 App 正在运行，滚动事件监听已启用；ClaudeGuard 已开启并返回“Clash/TUN 已就绪，Claude 通过代理访问”。TUN 保持开启，hosts 没有阻断条目，原 Merge 已还原，全局 Script 仅保留开启保护所需的标记段。后台批准始终保留，没有执行 unregister。

测试机器为 macOS 27.2 / arm64，构建目标仍为 macOS 14.0。没有读取或记录 Clash 控制密钥，没有改动 Claude 的记忆、账号、缓存或历史。管理和测试使用既有签名 XPC、当前用户拥有的 Unix controller socket，以及 Clash 自身的“重新激活订阅”入口。

## 滚动权限提示的实际问题

用户已经授权。旧 Bento PID 5167 的 TCC 日志返回 Accessibility 允许，但 `CGGetEventTapList` 仅有分屏监听，没有 scroll/gesture 监听。首次 `tapCreate` 失败被统一显示为“缺权限”；后来授权生效也没有自动重试。

优雅重启后，未改变任何权限开关，滚动监听立即恢复。修复版新增首次失败后的静默自愈，并区分授权未生效和事件监听创建失败。最后运行的 Bento PID 19663 有两个启用的 event tap，其中滚动 tap 的 `scroll=1, gesture=1, enabled=1`；App 自身日志为：

```text
AX=true, PostEvent=true, ListenEvent=0, tapCreated=true, tapEnabled=true
```

修改事件的 `.defaultTap` 依赖 Accessibility/PostEvent；不再额外强制申请输入监控。自动重试不弹授权框，成功会更新菜单并清除旧错误。首次失败、授权变化、单一定时器、停止重试和失败分类都有无真实输入的回归测试。

## XPC 授权根因与修复

旧代码将 KVC audit token 直接转换为 Data。真实匿名 NSXPC 实验输出：

```text
AUDIT: class=NSConcreteValue asData=false bytes=32 copy=0 validity=0 parse=0 match=0
```

失败发生在类型转换，尚未进入 SecCode 检查。正确解包后，token 长度、SecCode 创建、基本 validity、测试客户端 requirement 解析及匹配均正常。

生产代码使用 [Foundation 的 setCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))，在 resume 前设置逐消息签名门禁。要求从 daemon 自身已验证的签名派生，仅替换准确的 identifier；sidecar 不能扩大信任。App、sidecar 和 daemon 派生要求一致，保留 Apple/Developer ID 证书约束及 Team ID RV3FMJ29RW。

真实 root daemon 验证中，授权 Bento 的 on/status/restart/off 调用均成功；另行编译、ad-hoc 签名为同一 `com.sz.bento` identifier 的只读客户端返回 `NSCocoaErrorDomain 4097`，没有收到 service reply。拒绝前后授权 status 均成功，因此并非把服务不可用算作拒绝成功。该结果在 daemon 重启后再次确认。

## 此前遗漏的 Clash 兼容问题

本机 Clash Verge 为 2.5.8。此前向全局 Merge 写 `prepend-rules` 的做法不适用：[官方文档](https://www.clashverge.dev/guide/extend.html)和 [2.5.8 Merge 实现](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.8/src-tauri/src/enhance/merge.rs)均表明它没有这项前置运算。实机原运行规则共 211 条，anthropic.com/claude.ai 在第 38/39 条，另外三个保护后缀没有独立规则。

现在在原全局 `profiles/Script.js` 后追加受标记 wrapper：先调用原 main，再前置五条规则，保留其它字段和规则；迁移清理旧 Merge 标记。root 不执行用户 JS，仅接受可安全识别的标准 `function main`，不支持的语法明确报错并保持阻断。读写拒绝文件及父目录链接，使用目录描述符、原子替换和并发变更检查，保留 owner/mode。后置订阅脚本仍可能覆盖规则，所以最终运行态前五条验证继续保留。

外部改文件不会自动触发 Verge 的增强配置生成，首次安装后实际使用“订阅 → 重新激活订阅”加载；后续 Verge 重启或重新生成配置会继续执行持久规则。另修复了运行配置代理组解析只认两格缩进的问题，支持合法的 0/2/4 格序列及 name/type 顺序。

## 真实功能验证结果

| 检查 | 真实结果 |
| --- | --- |
| on / status | 返回开启和“Clash/TUN 已就绪”；当前 PROXY 为 Selector，选中节点为 Vless |
| 最终规则 | 共 214 条；前五条分别为 claude.ai、claude.com、claudeusercontent.com、claudemcpcontent.com、anthropic.com，均 DomainSuffix → PROXY；原两条完全相同规则去重，其余规则保留 |
| 连续 on 与周期维护 | 两次 on 后再等待周期维护，hosts、Merge、Script 的 SHA-256 和 mtime 均不变 |
| TUN 真实关闭 | 通过 [Mihomo PATCH /configs](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/configs.go)仅切换 tun.enable；daemon 报 TUN 设备没有有效地址，hosts 出现一个管理段，两个指定域名的系统 getaddrinfo 均得到 127.0.0.1 和 ::1 |
| TUN 自动恢复 | 同一测试进程在 finally 恢复 TUN；daemon 自动清除 hosts，两个域名分别恢复为 198.18.0.99 和 198.18.0.34（Clash Fake-IP），status 恢复已就绪 |
| App 退出 | 上述完整 TUN 正反测试期间没有 Bento GUI 进程，daemon 独立维护；之后已恢复 App |
| daemon 重启 | 固定 XPC restart 后 PID 19111 → 20072、launchd runs 4 → 5；启用状态保留并自动恢复已就绪；测试未 unregister |
| off 清理 | off --keep-registered 后 hosts、Merge、Script 均逐字节恢复基线，owner/mode 保留；再次激活订阅后运行规则回到原 211 条 |
| 恢复用户设置 | 完成清理验证后重新 on 并激活配置，最终保护开启、TUN 开启、原订阅和节点保持；hosts 无阻断，仅 Script 保留一份正常保护标记 |
| macOS 整机重启 | 本次验收没有为测试重启整机；不能将 daemon 重启当作整机启动验证 |

TUN 测试脚本先确认就绪，再关闭 TUN；失败、异常或中断均有恢复路径。以上结果是实际 DNS、文件、进程和 controller 响应，并非从编译成功推断。

## 构建与回归

- `./build_app.sh --test`：12 组全部通过，包括真实匿名 NSXPC 正反测试、Clash Script JavaScriptCore fixture、代理组缩进、TUN/模式/代理选择、DNS 重试、重启及滚动恢复。
- `BENTO_CODESIGN_IDENTITY="Developer ID Application: Shifeng Zhao (RV3FMJ29RW)" ./build_app.sh`：通过，App 与 daemon 保持 Developer ID + Hardened Runtime。
- `codesign --verify --strict --deep Bento.app`：通过。
- `git diff --check`：通过。

JavaScriptCore 只运行测试 fixture，不执行用户脚本。匿名 XPC 测试需要系统 CodeSigningHelper；受限执行沙箱中的 transport 错误不能充当身份验证结果。

基线 hosts SHA-256：`c7dd0e2ed261ce76d76f852596c5b54026b9a894fa481381ffd399b556c0e2da`；Merge：`20bdcc590225f6847cc87cfadd7fa0e596a545841b17d471f7e52991deaddb86`；原 Script：`d60fb84abefb54e550bd1dead6ed16986b119d8b3890efd6f1ead9c6d151d45b`。清理阶段三者全部一致；最终开启阶段 hosts/Merge 仍一致，Script 的差异仅为受管 wrapper。
