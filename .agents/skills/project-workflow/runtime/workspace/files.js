import * as fs from 'node:fs/promises';
import path from 'node:path';
import { digest, FactoryError, safePath, relativePath } from '../storage/index.js';
                                                                                                    

export const statuses = ['candidate', 'supported', 'disputed', 'stale'];
export const taskStatuses = ['open', 'in-progress', 'blocked', 'done', 'cancelled'];
                                                                    
                                                                                                                                                           

export function requireValue(condition         , message        )                    {
  if (!condition) throw new FactoryError(message, 3);
}
export function text(value         , name        )                          {
  requireValue(typeof value === 'string' && value.trim().length > 0, `${name} 必须为非空文本`);
}
export function name(value         ) {
  requireValue(typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,119}$/.test(value), `无效的资料标识：${value}`);
  return value;
}
export function topicPath(topic        ) {
  name(topic);
  requireValue(topic !== 'index', 'index 是保留的主题名称');
  return `.factory/memory/${topic}.md`;
}
export function projectPath(value        ) {
  requireValue(typeof value === 'string', '来源与范围必须使用项目内相对路径');
  relativePath(value);
  requireValue(value !== '.' && path.posix.normalize(value) === value, `请使用规范的项目内相对路径：${value}`);
  return value;
}
export function expected(value         ) {
  requireValue(value === null || (typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)), 'expectedDigest 必须是 SHA-256 或 null');
}
export async function root(options                  ) {
  requireValue(typeof options?.project === 'string' && path.isAbsolute(options.project), 'project 必须是项目绝对路径');
  const project = await fs.realpath(options.project);
  requireValue((await fs.stat(project)).isDirectory(), 'project 必须是目录');
  await safePath(project, '.factory');
  return project;
}
export async function read(project        , file        )                         {
  const target = await safePath(project, file);
  try { return await fs.readFile(target, 'utf8'); }
  catch (error) { if ((error                         ).code === 'ENOENT') return null; throw error; }
}
export async function hash(project        , file        ) {
  const target = await safePath(project, file);
  try { return digest(await fs.readFile(target)); }
  catch (error) { if ((error                         ).code === 'ENOENT') return null; throw error; }
}
export async function entries(project        , directory        ) {
  const target = await safePath(project, directory);
  try { return (await fs.readdir(target)).sort(); }
  catch (error) { if ((error                         ).code === 'ENOENT') return []; throw error; }
}
export function parseJSON(content        , file        )      {
  try { return JSON.parse(content); }
  catch { throw new FactoryError(`资料不是有效 JSON：${file}`, 3); }
}
export function validateSources(sources          ) {
  requireValue(Array.isArray(sources) && sources.length > 0, '整理必须提供项目内来源及摘要');
  const paths = new Set        ();
  for (const source of sources) {
    projectPath(source.path); expected(source.digest);
    requireValue(source.digest !== null && !paths.has(source.path), `来源摘要缺失或路径重复：${source.path}`);
    paths.add(source.path);
  }
}
export async function verifySources(project        , sources          ) {
  for (const source of sources) {
    requireValue(await hash(project, source.path) === source.digest, `来源版本冲突：${source.path}`);
  }
}
export function validateContent(content               ) {
  text(content?.title, '主题标题'); text(content?.body, '主题正文');
  requireValue(!/[\r\n]/.test(content.title), '主题标题必须为单行');
  requireValue(statuses.includes(content.status), '主题状态必须为 candidate/supported/disputed/stale');
  requireValue(Array.isArray(content.scope) && content.scope.length > 0, '主题必须声明适用范围');
  for (const scope of content.scope) if (scope !== '*') projectPath(scope);
  requireValue(Array.isArray(content.sources) && content.sources.length > 0, '主题必须声明来源');
  for (const source of content.sources) projectPath(source);
}
export function renderTopic(content               , sources          ) {
  validateContent(content);
  const selected = content.sources.map(file => {
    const source = sources.find(source => source.path === file);
    requireValue(source, `主题来源未包含在本次来源快照：${file}`);
    return source;
  });
  return `# ${content.title}\n\nStatus: ${content.status}\nScope: ${JSON.stringify(content.scope)}\nSources: ${JSON.stringify(selected)}\n\n${content.body.trim()}\n`;
}
export function parseTopic(content        , topic        )        {
  const file = topicPath(topic);
  const match = content.match(/^# ([^\r\n]+)\r?\n\r?\nStatus: ([^\r\n]+)\r?\nScope: ([^\r\n]+)\r?\nSources: ([^\r\n]+)\r?\n\r?\n([\s\S]+)$/);
  requireValue(match, `主题格式无效：${file}`);
  const [, title, status, rawScope, rawSources, body] = match;
  const scope = parseJSON(rawScope, file), sources           = parseJSON(rawSources, file);
  validateSources(sources);
  validateContent({ title, status: status                , scope, sources: sources.map(source => source.path), body });
  return { topic, path: file, digest: digest(content), title, status: status                , scope, sources, body };
}
export function validateTask(task            , reportEvidenceIssue                            ) {
  name(task?.id); text(task?.goal, '任务目标');
  requireValue(taskStatuses.includes(task.status), '任务必须显式提供有效状态');
  if (task.ticket !== undefined) text(task.ticket, '原票链接');
  for (const key of ['baselines', 'evidence', 'unfinished', 'candidates']         ) {
    requireValue(task[key] === undefined || Array.isArray(task[key]), `任务 ${key} 必须为数组`);
  }
  for (const base of task.baselines || []) { if (base.repo !== '.') projectPath(base.repo); text(base.ref, '仓库基线'); }
  const evidence = task.evidence?.filter((entry, index) => {
    try {
      projectPath(entry?.path);
    } catch (error) {
      const message = `evidence[${index}].path 应指向项目内的证据文件，可改填归档回执的相对路径。（${(error         ).message}）`;
      requireValue(reportEvidenceIssue, message);
      reportEvidenceIssue(message);
      return false;
    }
    text(entry.result, `evidence[${index}].result`);
    return true;
  });
  for (const unfinished of task.unfinished || []) text(unfinished, '未完成项');
  for (const candidate of task.candidates || []) {
    name(candidate.id); text(candidate.text, '候选经验');
    requireValue(candidate.sources === undefined || Array.isArray(candidate.sources), '候选来源必须为数组');
    for (const source of candidate.sources || []) projectPath(source);
  }
  return evidence;
}
export async function scanTopics(project        ) {
  const topics          = [], issues          = [];
  for (const file of await entries(project, '.factory/memory')) {
    if (!file.endsWith('.md') || file === 'index.md') continue;
    const relative = `.factory/memory/${file}`;
    try {
      const content = await read(project, relative);
      requireValue(content !== null, `主题读取时已移除：${relative}`);
      topics.push(parseTopic(content, file.slice(0, -3)));
    } catch (error) { issues.push({ code: 'invalid-topic', path: relative, message: (error         ).message }); }
  }
  return { topics, issues };
}
export function renderIndex(topics         ) {
  const lines = [...topics].sort((a, b) => a.topic.localeCompare(b.topic)).map(topic =>
    `- [${topic.topic}](${topic.topic}.md) | ${topic.status} | ${JSON.stringify(topic.scope)} | ${topic.digest}`);
  return '# 主题索引\n\n此文件可重建；主题正文是依据。candidate 仅供调查，supported 也不授予权限。disputed/stale 不作为默认建议。\n\n' + lines.join('\n') + '\n';
}
export function canonical(value     )      {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
