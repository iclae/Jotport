# Jotport 本机更新约定

Status: supported
Scope: ["*"]
Sources: [{"path":".factory/history/remember-app-local-update-2026-11-19.md","digest":"1705c694d871c5fea143fd1666462f7b8afac2db9d78971495ca3a72c2f29538"}]

在用户这台 Mac 上，Jotport App 的界面、功能或修复改动验证通过后，交付时更新本机已安装版本。使用 `scripts/package.sh` 构建，正常退出旧版并替换 `/Applications/Jotport.app`，保留原有用户数据。核对签名和构建产物，再启动新版并确认运行。
