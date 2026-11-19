# GitHub Issues

在 `iclae/Jotport` 的 GitHub Issues 中跟踪 Issue 和规格。使用 `gh` 操作。写入前用 `gh repo view --json nameWithOwner` 确认目标，写入命令指定 `--repo iclae/Jotport`。

## Issue 操作

- 发布 Issue 或规格时，运行 `gh issue create --title '<标题>' --body-file <正文文件>`。
- 读取 Issue 时，运行 `gh issue view <编号> --json number,title,body,labels,comments`。
- 列出 Issue 时，运行 `gh issue list --state open --json number,title,body,labels,comments`。按需调整 `--state` 和 `--label`。
- 添加评论时，运行 `gh issue comment <编号> --body-file <正文文件>`。
- 添加或移除标签时，运行 `gh issue edit <编号> --add-label '<标签>'` 或 `gh issue edit <编号> --remove-label '<标签>'`。
- 需要说明关闭原因时，先添加评论，再运行 `gh issue close <编号>`。已关闭的 Issue 也用 `gh issue comment` 补充说明。

## 子 Issue 和依赖

- 新建子 Issue 时使用 `gh issue create --parent <父编号>`。关联已有 Issue 时使用 `gh issue edit <父编号> --add-sub-issue <子编号>`。无法建立原生关联时，在子 Issue 正文开头写 `Part of #<父编号>`。
- 新建 Issue 时用 `gh issue create --blocked-by <阻塞编号>,<阻塞编号>` 记录依赖。为现有 Issue 添加依赖时用 `gh issue edit <子编号> --add-blocked-by <阻塞编号>`。无法建立原生依赖时，在正文开头写 `Blocked by: #<编号>, #<编号>`。
- 用 `gh api repos/iclae/Jotport/issues/<编号> --jq .issue_dependencies_summary.blocked_by` 查询尚未关闭的原生阻塞项数量。正文记录的阻塞项需要逐一检查状态。所有阻塞项关闭后，Issue 才能开始。

## Pull request 分诊

**PRs as a request surface: no.**

如果启用此选项，外部 PR 使用与 Issue 相同的分诊状态和标签。通过 `gh api --paginate 'repos/iclae/Jotport/pulls?state=open'` 列出开放 PR，排除 `author_association` 为 `OWNER`、`MEMBER` 或 `COLLABORATOR` 的条目。用 `gh pr view`、`gh pr view <编号> --comments` 和 `gh pr diff` 读取内容。用 `gh pr comment`、`gh pr edit` 和 `gh pr close` 更新。

GitHub 的 Issue 和 PR 共用编号。类型不明时，先用 `gh pr view <编号>` 查询，再用 `gh issue view <编号>` 查询。

## Wayfinder

- 用带 `wayfinder:map` 标签的 Issue 记录工作地图。将票据关联为子 Issue，并按类型加上 `wayfinder:research`、`wayfinder:prototype`、`wayfinder:grilling` 或 `wayfinder:task`。无法建立原生子 Issue 时，在地图中添加任务清单，并在子 Issue 写明 `Part of #<地图编号>`。
- 按地图顺序选择首个仍开放、无未关闭阻塞项、未分配的票据。开始前用 `gh issue edit <编号> --add-assignee @me` 认领。
- 完成票据时，先用评论记录答案，再关闭票据。将相关 gist 链接补到地图的 `Decisions-so-far`。
