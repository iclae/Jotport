import * as fs from 'node:fs/promises';
import { atomicWrite, digest, json, now, safePath, withLock } from '../storage/index.js';
import { canonical, entries, expected, hash, name, parseJSON, parseTopic, read, renderIndex, renderTopic, requireValue, root, scanTopics, text, topicPath, validateSources, verifySources } from './files.js';
                                                                             

                                                                                                   
                                                                                                                                    

function validate(input                  ) {
  name(input?.id);
  requireValue(Array.isArray(input.sources) && Array.isArray(input.operations), '整理必须提供 sources 和 operations 数组');
  if (input.operations.length || input.sources.length) validateSources(input.sources);
  const topics = new Set        ();
  for (const operation of input.operations) {
    topicPath(operation.topic); expected(operation.expectedDigest); text(operation.reason, '整理理由');
    requireValue(!topics.has(operation.topic), `一次整理不能重复操作同一主题：${operation.topic}`);
    topics.add(operation.topic);
    requireValue(operation.op === 'upsert' || operation.op === 'archive', '整理操作必须为 upsert 或 archive');
    if (operation.op === 'archive') requireValue(operation.expectedDigest !== null, '归档必须指定已有主题摘要');
    else renderTopic(operation.content, input.sources);
  }
}

export async function pendingFiles(project        ) {
  return (await entries(project, '.factory/history')).filter(file => file.startsWith('consolidate-') && file.endsWith('.pending.json'));
}

async function prepare(project        , input                  , requestDigest        )                {
  await verifySources(project, input.sources);
  const writes          = [];
  const { topics } = await scanTopics(project);
  const resultTopics = new Map(topics.map(topic => [topic.topic, topic]));
  const changes = [];
  async function add(file        , content               , before               ) {
    writes.push({ path: file, before, after: content === null ? null : digest(content), content });
  }
  for (const operation of input.operations) {
    const file = topicPath(operation.topic), previous = await read(project, file);
    const before = previous === null ? null : digest(previous);
    requireValue(before === operation.expectedDigest, `主题版本冲突：${file}`);
    let archived                    ;
    if (previous !== null) {
      archived = `.factory/memory/archive/${operation.topic}/${input.id}.md`;
      requireValue(await hash(project, archived) === null, `归档路径已存在：${archived}`);
      await add(archived, previous, null);
    }
    const content = operation.op === 'upsert' ? renderTopic(operation.content, input.sources) : null;
    await add(file, content, before);
    if (content === null) resultTopics.delete(operation.topic);
    else resultTopics.set(operation.topic, parseTopic(content, operation.topic));
    changes.push({ topic: operation.topic, op: operation.op, reason: operation.reason, before, after: content === null ? null : digest(content), ...(archived ? { archived } : {}) });
  }
  const index = '.factory/memory/index.md';
  await add(index, renderIndex([...resultTopics.values()]), await hash(project, index));
  for (const source of input.sources) {
    requireValue(!writes.some(write => write.path === source.path), `来源不能同时作为本次写入目标：${source.path}`);
  }
  const receipt = { version: 1, id: input.id, status: 'applied', requestDigest, sources: input.sources, changes, createdAt: now() };
  const plan = { version: 1         , id: input.id, requestDigest, sources: input.sources, writes, receipt };
  return { ...plan, planDigest: digest(canonical(plan)) };
}

async function apply(project        , plan      , pending        , receiptPath        ) {
  const { planDigest, ...body } = plan;
  requireValue(planDigest === digest(canonical(body)), `暂存清单摘要不匹配：${pending}`);
  await verifySources(project, plan.sources);
  // 在任何恢复写入前核对全部目标，允许已经写入的新版或尚未写入的旧版。
  for (const write of plan.writes) {
    const current = await hash(project, write.path);
    requireValue(current === write.before || current === write.after, `整理恢复冲突：${write.path}`);
  }
  for (const write of plan.writes) {
    await verifySources(project, plan.sources);
    const current = await hash(project, write.path);
    if (current === write.after) continue;
    requireValue(current === write.before, `整理写入冲突：${write.path}`);
    const file = await safePath(project, write.path);
    if (write.content === null) await fs.rm(file);
    else await atomicWrite(file, write.content);
  }
  await atomicWrite(await safePath(project, receiptPath), json(plan.receipt));
  await fs.rm(await safePath(project, pending));
  return { ...plan.receipt, replayed: false };
}

export async function workspaceConsolidate(input                  , options                  ) {
  validate(input);
  const project = await root(options);
  return withLock(await safePath(project, '.factory'), async () => {
    const requestDigest = digest(canonical(input));
    const receiptPath = `.factory/history/consolidate-${input.id}.json`;
    const pending = `.factory/history/consolidate-${input.id}.pending.json`;
    const completed = await read(project, receiptPath);
    if (completed !== null) {
      const receipt = parseJSON(completed, receiptPath);
      requireValue(receipt.requestDigest === requestDigest, `整理 id 已被不同内容使用：${input.id}`);
      const staged = await read(project, pending);
      if (staged !== null) {
        requireValue(parseJSON(staged, pending).requestDigest === requestDigest, `暂存请求不匹配：${pending}`);
        await fs.rm(await safePath(project, pending));
      }
      return { ...receipt, replayed: true };
    }
    const other = (await pendingFiles(project)).filter(file => `.factory/history/${file}` !== pending);
    requireValue(other.length === 0, `存在未完成整理，请先恢复：${other.join(', ')}`);
    const staged = await read(project, pending);
    let plan      ;
    if (staged !== null) {
      plan = parseJSON(staged, pending);
      requireValue(plan.requestDigest === requestDigest, `整理 id 已被不同内容使用：${input.id}`);
    } else {
      plan = await prepare(project, input, requestDigest);
      await atomicWrite(await safePath(project, pending), json(plan));
    }
    return apply(project, plan, pending, receiptPath);
  });
}
