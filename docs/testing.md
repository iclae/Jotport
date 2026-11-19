# 0.1 测试构建：安装和已知限制

这是可安装的原生笔记原型，不是已完成首版验收的发布版本。原规格保持不变。

## 下载与安装
在 PR 的 Actions 中下载 `Jotport-macOS12-Intel` artifact，解压外层，再解压 `Jotport-macOS12-Intel.app.zip`，把 `Jotport.app` 拖到 Applications。最低系统 macOS 12，Intel x86_64。构建使用 ad-hoc 签名，尚未 Developer ID 签名/公证。首次打开可能需 Finder 右键“打开”并在系统安全设置允许此应用；不要关闭系统整体安全检查。SHA256SUMS 用于核对下载包。

## 可测试功能
原生多段编辑、同步 SQLite 自动保存、正文/关联 ID/概况搜索、包含归档、置顶、同分区拖动、整块复制、归档恢复、持久删除撤销、窗口置顶。数据位于 `~/Library/Application Support/Jotport`。退出应用、归档和删除不会结束 agent。

直接在各块内编辑正文。鼠标悬停时，通过左侧手柄排序，或通过右侧「…」展开块快捷操作。点击「…」可查看完整菜单。「编辑」菜单下的「撤销删除块」可恢复最近删除的块。块有最近回复摘录时，可在摘录右侧隐藏，也可从「…」菜单中重新打开。

在「设置」中可调整块快捷操作的顺序，也可指定默认终端、默认 agent、终端的 `.app` 路径、agent 可执行文件和工作目录。Codex 默认优先使用 `~/.npm-global/bin/codex`。Jotport 也会查找 `/usr/local/bin`、`~/.local/bin` 和登录 shell 的 `PATH`。探测 agent 版本和启动 agent 使用同一份 `PATH`。自定义参数当前仅接受空数组 `[]`，避免 CLI 自动发送初始提示词。终端和 agent 的探测结果保存在 `last-probe.txt`。

终端已运行时，Jotport 在现有应用中打开标签页。首次用 Jotport 在已打开的 Ghostty 中创建标签页时，macOS 可能要求授予自动化权限。终端尚未运行时，Jotport 会启动它并执行启动脚本。再次点击「启动 / 返回」会激活已记录的终端应用，请在其中选择对应标签页。若出现「上一次启动未确认」，先检查原终端中是否有对应会话。确认没有后，点击「确认重试」以使用当前默认设置重试。

pi 通过单次 `--extension` 加载随包扩展，不写全局配置。扩展从 sessionManager 获取原生 ID；编辑 API 可用时只调用 setEditorText，绝不 sendMessage。预填尝试标记先持久化，避免扩展 reload 后重注入。agent_start 和 agent_settled 上报真实事件。较旧版本缺少最终事件时不能判定完成。需要输入/授权的细分类别尚未接入。

Codex 当前只会打开 CLI。点击「复制」，看到「已复制」后，在 CLI 中粘贴并发送。尚未接入 Codex 正式 hooks，不自动绑定真实 ID、不伪造状态，不扫描 ~/.codex。按 ID 恢复目前仅对已收到退出事件及真实 ID 的关联开放。不得把该组合标为自动预填通过。

## 撤销接入
结束自己需要结束的终端会话；退出 Jotport 并删除 app。pi 扩展只通过本次启动参数加载，不修改用户配置。要保留笔记，保留 Application Support/Jotport；删除该目录会删除笔记、会话关联和事件，不会终止终端进程。

## 尚未完成
四组合（Ghostty 1.4.0/WezTerm × Codex/pi）的 macOS 12 Intel 实机验收全部待做。CI 仅证明在较新 macOS 编译/启动，不能证明 Monterey 运行、中文输入法、Spaces/全屏、登录/信任提示时预填、具体 pane 定位、异常退出/唤醒对账、按原 ID 恢复。Codex hooks、可靠 pane 控制、独立结束 agent、单块目录覆盖、编辑期间关注重排的完整顺序与持久化、归档关注专门入口、资源测量均待完成。不会将这些缺口从首版规格删除。

本机构建：安装 Xcode 命令行工具，运行 `swift test` 和 `bash scripts/package.sh`。Linux 可使用 Swift 5.10 + libsqlite3-dev 执行 `swift test`；UI 在 Linux 不运行。
