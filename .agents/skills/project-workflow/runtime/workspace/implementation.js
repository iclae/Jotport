import * as fs from 'node:fs/promises';
import { atomicWrite, digest, json, now, safePath, withLock } from '../storage/index.js';
import { entries, expected, hash, name, parseJSON, projectPath, read, renderIndex, requireValue, root, scanTopics, validateTask } from './files.js';
                                        
import { pendingFiles } from './transaction.js';
                                                                

const defaultWorkflow = `# 项目执行与资料约定

直接接受明确需求或原票，按需调查、实施和验证。小任务无需强制登记。权限由用户和适用规则决定，任务记录与经验不会增加权限。

项目资料无需 Factory 或 Node 即可读取和编辑：
- tasks/<id>.json：目标、原票链接、显式任务状态、多仓基线、真实证据、未完成项和可选候选经验。业务完成与经验整理相互独立。
- memory/<topic>.md：主题正文为依据；index.md 仅为可重建索引。格式依次为标题、空行、Status、Scope、Sources、空行、自然正文。
- Status 取 candidate（待验证）、supported（有来源支持，仍需核对适用范围）、disputed（有争议）或 stale（已失效）。默认不采用 disputed/stale。
- Scope 是项目内相对路径的 JSON 数组，全项目用 ["*"]。Sources 是 [{"path":"项目内相对路径","digest":"SHA-256"}]；摘要与读取时文件一致。不将资料存在或重复次数视为已验证。
- history/ 保留整理回执及中断时的暂存清单；memory/archive/ 保留被替代或归档的原文。

整理的语义判断由当前 agent 完成。明确选择来源、主题与修改理由，核对来源及目标摘要后更新，遇到版本冲突保留新事实。无需启动额外模型。无新增经验时直接结束，不强制空复盘。

人工编辑主题后可直接继续；读取正文确认状态、来源和范围，不依赖旧索引。使用辅助整理时，同一请求 id 只对应同一内容。中断后重跑原请求；若残留 .writer-lock，确认没有写入进程后才可移除。不要删除尚未恢复的暂存清单。
`;

export async function workspaceInit(options                  ) {
  const project = await root(options);
  return withLock(await safePath(project, '.factory'), async () => {
    for (const directory of ['tasks', 'memory/archive', 'history']) {
      await fs.mkdir(await safePath(project, `.factory/${directory}`), { recursive: true, mode: 0o700 });
    }
    const created           = [];
    for (const [file, content] of [
      ['.factory/workflow.md', options.workflow ?? defaultWorkflow],
      ['.factory/memory/index.md', renderIndex((await scanTopics(project)).topics)],
    ]) {
      if (await read(project, file) !== null) continue;
      // wx 也保护不使用本模块锁的人工初始化；既有文件始终保留。
      try { await fs.writeFile(await safePath(project, file), content, { flag: 'wx', mode: 0o600 }); created.push(file); }
      catch (error) { if ((error                         ).code !== 'EEXIST') throw error; }
    }
    return { project, created, workflow: '.factory/workflow.md' };
  });
}

export async function workspaceRecord(input             , options                  ) {
  validateTask(input?.task); expected(input.expectedDigest);
  const project = await root(options), file = `.factory/tasks/${input.task.id}.json`;
  return withLock(await safePath(project, '.factory'), async () => {
    const content = json(input.task), nextDigest = digest(content), current = await hash(project, file);
    const receipt = `.factory/history/task-${input.task.id}-${nextDigest}.json`;
    const saved = await read(project, receipt);
    let record = saved === null ? null : parseJSON(saved, receipt);
    if (current === nextDigest && record && record.status !== 'prepared') return { path: file, digest: nextDigest, receipt, replayed: true };
    requireValue(current === input.expectedDigest || current === nextDigest, `任务版本冲突：${file}`);
    if (!record) {
      const sources = [];
      for (const evidence of input.task.evidence || []) {
        const evidenceDigest = await hash(project, evidence.path);
        requireValue(evidenceDigest !== null, `证据文件不存在：${evidence.path}`);
        sources.push({ path: evidence.path, digest: evidenceDigest });
      }
      for (const candidate of input.task.candidates || []) {
        for (const source of candidate.sources || []) requireValue(await hash(project, source) !== null, `候选来源文件不存在：${source}`);
      }
      record = { version: 1, task: input.task.id, before: current === nextDigest ? null : current, after: nextDigest, sources, recordedAt: now(), status: 'prepared', observedExisting: current === nextDigest };
      await atomicWrite(await safePath(project, receipt), json(record));
    }
    requireValue(await hash(project, file) === current, `任务写入前已变化：${file}`);
    if (current !== nextDigest) await atomicWrite(await safePath(project, file), content);
    await atomicWrite(await safePath(project, receipt), json({ ...record, status: 'completed' }));
    return { path: file, digest: nextDigest, receipt, replayed: current === nextDigest };
  });
}

async function inspect(project        ) {
  const { topics, issues } = await scanTopics(project);
  const tasks = [];
  if (await read(project, '.factory/workflow.md') === null) issues.push({ code: 'missing-workflow', path: '.factory/workflow.md', message: '项目流程文件尚未创建' });
  const index = await read(project, '.factory/memory/index.md');
  const indexFresh = index === renderIndex(topics);
  if (!indexFresh) issues.push({ code: 'stale-index', path: '.factory/memory/index.md', message: '索引缺失或过期；读取主题正文，空 operations 整理可重建索引' });
  const changedSources = new Set        ();
  const sourceHashes = new Map                       ();
  for (const topic of topics) {
    for (const source of topic.sources) {
      try {
        if (!sourceHashes.has(source.path)) sourceHashes.set(source.path, await hash(project, source.path));
        if (sourceHashes.get(source.path) === source.digest) continue;
        changedSources.add(topic.topic);
        issues.push({ code: 'source-changed', path: topic.path, message: `来源已改变或缺失：${source.path}` });
      } catch (error) {
        changedSources.add(topic.topic);
        issues.push({ code: 'source-unreadable', path: topic.path, message: (error         ).message });
      }
    }
    if (topic.status === 'disputed' || topic.status === 'stale') issues.push({ code: topic.status, path: topic.path, message: `主题状态为 ${topic.status}，不作为默认建议` });
  }
  for (const file of await entries(project, '.factory/tasks')) {
    if (!file.endsWith('.json')) continue;
    const relative = `.factory/tasks/${file}`;
    try {
      const content = await read(project, relative);
      requireValue(content !== null, `任务读取时已移除：${relative}`);
      const task = parseJSON(content, relative);
      const evidence = validateTask(task, message => issues.push({ code: 'invalid-evidence', path: relative, message }));
      if (evidence) task.evidence = evidence;
      requireValue(`${task.id}.json` === file, `任务 id 与文件名不一致：${relative}`);
      tasks.push({ ...task, path: relative, digest: digest(content) });
    } catch (error) { issues.push({ code: 'invalid-task', path: relative, message: (error         ).message }); }
  }
  const pendingTopics = new Set        ();
  let unknownPending = false;
  for (const file of await pendingFiles(project)) {
    const relative = `.factory/history/${file}`;
    issues.push({ code: 'pending-transaction', path: relative, message: '整理尚未完成，重跑原请求恢复' });
    try {
      const staged = parseJSON((await read(project, relative)) , relative);
      for (const change of staged.receipt.changes) pendingTopics.add(change.topic);
    } catch (error) {
      unknownPending = true;
      issues.push({ code: 'invalid-transaction', path: relative, message: (error         ).message });
    }
  }
  return { topics, tasks, issues, indexFresh, changedSources, pendingTopics, unknownPending };
}

export async function workspaceCheck(options                  ) {
  const project = await root(options);
  const state = await inspect(project);
  return { project, ok: state.issues.length === 0, indexFresh: state.indexFresh, tasks: state.tasks.length, topics: state.topics.length, issues: state.issues };
}

export async function workspaceContext(options                  ) {
  const project = await root(options), state = await inspect(project);
  const limit = options.limit ?? 8;
  requireValue(Number.isInteger(limit) && limit > 0 && limit <= 50, 'limit 必须为 1 到 50 的整数');
  if (options.scope !== undefined && options.scope !== '.') projectPath(options.scope);
  if (options.task !== undefined) name(options.task);
  if (options.topics !== undefined) {
    requireValue(Array.isArray(options.topics), 'topics 必须为数组');
    for (const topic of options.topics) name(topic);
  }
  const words = (options.query || '').toLocaleLowerCase().split(/\s+/).filter(Boolean);
  const match = (value        ) => words.every(word => value.toLocaleLowerCase().includes(word));
  const active = state.tasks.filter(task => !['done', 'cancelled'].includes(task.status));
  const task = options.task ? state.tasks.find(task => task.id === options.task) ?? null : active.length === 1 ? active[0] : null;
  const issues          = [...state.issues];
  if (options.task) {
    const path = `.factory/tasks/${options.task}.json`;
    issues.sort((a, b) => Number(b.path === path) - Number(a.path === path));
    if (!task && !issues.some(issue => issue.path === path)) {
      issues.unshift({ code: 'task-not-found', path, message: '指定任务不存在' });
    }
  }
  const scope = options.scope;
  const memory = state.topics.filter(topic => {
    if (options.topics && !options.topics.includes(topic.topic)) return false;
    if (scope !== undefined && !topic.scope.some(prefix => prefix === '*' || scope === prefix || scope.startsWith(`${prefix}/`))) return false;
    if (!match(`${topic.topic} ${topic.title} ${topic.body} ${topic.scope.join(' ')}`)) return false;
    return options.diagnostics || (!['disputed', 'stale'].includes(topic.status) && !state.changedSources.has(topic.topic) && !state.pendingTopics.has(topic.topic) && !state.unknownPending);
  }).map(topic => ({
    topic: topic.topic, title: topic.title, path: topic.path, digest: topic.digest, status: topic.status, scope: topic.scope,
    use: state.changedSources.has(topic.topic) || state.pendingTopics.has(topic.topic) || state.unknownPending || ['disputed', 'stale'].includes(topic.status)
      ? 'diagnostic' : topic.status === 'candidate' ? 'investigation' : 'reference',
  }));
  const taskIndex = (options.task ? state.tasks.filter(item => item.id === options.task) : active).filter(item => match(`${item.id} ${item.goal}`));
  return {
    project, workflow: '.factory/workflow.md', index: '.factory/memory/index.md', indexFresh: state.indexFresh,
    authority: 'reference-only', task,
    tasks: taskIndex.slice(0, limit).map(item => ({ id: item.id, goal: item.goal, status: item.status, path: item.path, digest: item.digest })),
    memory: memory.slice(0, limit),
    omitted: { tasks: Math.max(0, taskIndex.length - limit), memory: Math.max(0, memory.length - limit) },
    issues: issues.slice(0, limit), issueCount: issues.length,
  };
}
