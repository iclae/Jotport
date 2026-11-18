# 0.1 测试构建：安装和已知限制

这是可安装的原生笔记原型，不是已完成首版验收的发布版本。原规格保持不变。

## 下载与安装
在 PR 的 Actions 中下载 `Jotport-macOS12-Intel` artifact，解压外层，再解压 `Jotport-macOS12-Intel.app.zip`，把 `Jotport.app` 拖到 Applications。最低系统 macOS 12，Intel x86_64。构建使用 ad-hoc 签名，尚未 Developer ID 签名/公证。首次打开可能需 Finder 右键“打开”并在系统安全设置允许此应用；不要关闭系统整体安全检查。SHA256SUMS 用于核对下载包。

## 可测试功能
原生多段编辑、同步 SQLite 自动保存、正文/关联 ID/概况搜索、包含归档、置顶、同分区拖动、整块复制、归档恢复、持久删除撤销、窗口置顶。数据位于 `~/Library/Application Support/Jotport`。退出应用、归档和删除不会结束 agent。

设置终端实际 app 路径、CLI 可执行文件和目录。先选择 agent/终端，再在“设置”保存默认值。参数预留 JSON 字段，但当前拒绝非空数组，避免 CLI 初始 prompt 自动发送。运行时记录 bundle identity、版本/构建号、CLI version/help 与实际 sdef 到 `last-probe.txt`。这些诊断不是适配成功的证明。

WezTerm 使用所选安装包的 start 命令；Ghostty 只有探测到 -e 时才尝试命令启动。两者没有取得并验证具体 pane 的实现，返回仅在进程身份匹配时激活终端应用，并明确要求手动选择 pane。失败/超时/重启不会自动重放启动请求。未决启动目前需要人工核对，不能一键清锁。

pi 通过单次 `--extension` 加载随包扩展，不写全局配置。扩展从 sessionManager 获取原生 ID；编辑 API 可用时只调用 setEditorText，绝不 sendMessage。预填尝试标记先持久化，避免扩展 reload 后重注入。agent_start 和 agent_settled 上报真实事件。较旧版本缺少最终事件时不能判定完成。需要输入/授权的细分类别尚未接入。

Codex 当前是明确的“待粘贴”降级：仅打开 CLI，点击“复制正文”后手动粘贴并自行发送。尚未接入 Codex 正式 hooks，不自动绑定真实 ID、不伪造状态，不扫描 ~/.codex。按 ID 恢复目前仅对已收到退出事件及真实 ID 的关联开放。不得把该组合标为自动预填通过。

## 撤销接入
结束自己需要结束的终端会话；退出 Jotport 并删除 app。pi 扩展只通过本次启动参数加载，不修改用户配置。要保留笔记，保留 Application Support/Jotport；删除该目录会删除笔记、会话关联和事件，不会终止终端进程。

## 尚未完成
四组合（Ghostty 1.4.0/WezTerm × Codex/pi）的 macOS 12 Intel 实机验收全部待做。CI 仅证明在较新 macOS 编译/启动，不能证明 Monterey 运行、中文输入法、Spaces/全屏、登录/信任提示时预填、具体 pane 定位、异常退出/唤醒对账、按原 ID 恢复。Codex hooks、可靠 pane 控制、独立结束 agent、单块目录覆盖、编辑期间关注重排的完整顺序与持久化、归档关注专门入口、资源测量均待完成。不会将这些缺口从首版规格删除。

本机构建：安装 Xcode 命令行工具，运行 `swift test` 和 `bash scripts/package.sh`。Linux 可使用 Swift 5.10 + libsqlite3-dev 执行 `swift test`；UI 在 Linux 不运行。
