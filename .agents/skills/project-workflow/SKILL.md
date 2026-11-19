---
name: project-workflow
description: 收到本项目明确需求、已有票据或继续任务请求时，读取项目执行约定，推进实施、验证、交付、接续与经验整理。无需用户手动调用。
---

# 项目执行

所有路径均相对项目根目录。先读 `.factory/workflow.md`，存在 `.factory/policy.md` 时读取本项目补充。沿用当前用户授权、上游已确认需求和项目规则，直接推进。

接续按指定任务读取 `.factory/tasks/` 或原票。相关经验从 `.factory/memory/index.md` 按主题展开；收尾按流程完成本次经验整理。

资料可直接维护，不要求安装或访问 dream-factory。需要摘要检查、记录或幂等整理时，可选运行 `node .agents/skills/project-workflow/scripts/factory.mjs context|check|record|consolidate`；带输入的操作使用 `--input <JSON>`。可选脚本需要 Node.js 22.13+。没有兼容运行时就直接读取和维护资料，不能伪称已执行脚本检查。

首次手写任务或经验文件、调用 record/consolidate 时，读取项目内 .agents/skills/project-workflow/references/records.md 的格式与例子。

Herdr 两技能仅 Herdr 环境内且符合调用限制时使用；环境外和云端使用当前环境已有能力。配套工具的升级由维护者按已审阅计划完成，不属于普通业务任务。
