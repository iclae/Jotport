## Agent skills

### Issue tracker

在 `iclae/Jotport` 的 GitHub Issues 中跟踪 Issue 和规格。详见 `docs/agents/issue-tracker.md`。

### Triage labels

使用五个默认分诊标签。详见 `docs/agents/triage-labels.md`。

### Domain docs

使用单一上下文布局。详见 `docs/agents/domain.md`。

<!-- agent-workflow:start -->
收到明确需求、已有票据、继续任务请求，或用户明确要求记住项目约定时，自动读取项目 [project-workflow](.agents/skills/project-workflow/SKILL.md)，按 [.factory/workflow.md](.factory/workflow.md) 推进。无需用户手动调用；不支持 skill 的环境直接读取相同文件。项目包可独立运行，任务和经验保存在项目中。
<!-- agent-workflow:end -->
