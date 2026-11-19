import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';

export class FactoryError extends Error {
  code        ;
  details         ;
  constructor(message        , code = 2, details          = undefined) { super(message); this.code = code; this.details = details; }
}
export const now = () => new Date().toISOString();
export const id = (prefix = 'id') => `${prefix}-${randomUUID()}`;
export const digest = (value     ) => createHash('sha256').update(typeof value === 'string' || Buffer.isBuffer(value) ? value : JSON.stringify(value)).digest('hex');
export const json = (value     ) => JSON.stringify(value, null, 2) + '\n';
export async function exists(file        ) { try { await fs.lstat(file); return true; } catch (e) { if ((e                         ).code === 'ENOENT') return false; throw e; } }
export async function hashFile(file        ) { return await exists(file) ? digest(await fs.readFile(file)) : null; }
export async function readJSON(file        ) { try { return JSON.parse(await fs.readFile(file, 'utf8')); } catch (e) { throw new FactoryError(`无法读取 JSON：${file}：${(e         ).message}`); } }
export function relativePath(value        ) {
  if (!value || value.includes('\0') || path.isAbsolute(value) || path.win32.isAbsolute(value) || value.includes('\\') || value.split('/').includes('..')) throw new FactoryError(`不安全的相对路径：${value}`, 3);
  return value;
}
export async function safePath(root        , relative        ) {
  relativePath(relative);
  const base = path.resolve(root), target = path.resolve(base, relative);
  let current = base;
  // 根目录本身允许用户显式指定；其下任何符号链接都不跟随。
  for (const part of relative.split('/').filter(p => p !== '.')) {
    current = path.join(current, part);
    try { if ((await fs.lstat(current)).isSymbolicLink()) throw new FactoryError(`拒绝符号链接：${current}`, 3); } catch (e) { if ((e                         ).code !== 'ENOENT') throw e; }
  }
  return target;
}
export async function atomicWrite(file        , content     ) {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  try { await fs.writeFile(temporary, content, { mode: 0o600, flag: 'wx' }); await fs.rename(temporary, file); }
  finally { await fs.rm(temporary, { force: true }); }
}
export const writeJSON = (file        , value     ) => atomicWrite(file, json(value));
export async function withLock   (directory        , work                  )             {
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const lock = path.join(directory, '.writer-lock');
  try { await fs.mkdir(lock); } catch (e) { if ((e                         ).code === 'EEXIST') throw new FactoryError(`已有写入锁：${lock}；确认没有运行进程后才可人工移除`, 3); throw e; }
  try { await writeJSON(path.join(lock, 'owner.json'), { pid: process.pid, createdAt: now() }); return await work(); }
  finally { await fs.rm(lock, { recursive: true, force: true }); }
}
export function locations(options      = {}) {
  const project = path.resolve(options.project || process.cwd());
  const config = path.resolve(options.configDir || path.join(project, '.factory'));
  const state = path.resolve(options.stateDir || process.env.FACTORY_STATE_DIR || (process.platform === 'darwin' ? path.join(os.homedir(), 'Library/Application Support/agent-factory-toolkit') : path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local/share'), 'agent-factory-toolkit')));
  return { project, config, state };
}
export async function resolveLocations(options    ={}) {
  const loc=locations(options);
  if(!options.configDir&&(await fs.lstat(loc.config).catch(()=>null))?.isSymbolicLink())throw new FactoryError('默认配置目录是符号链接；请显式选择 --config-dir，不跟随隐式链接',3);
  if(options.configDir || await exists(path.join(loc.config,'project.json')) || !(await exists(loc.state)))return loc;
  const matches=[];
  for(const entry of (await fs.readdir(loc.state,{withFileTypes:true})).slice(0,1000))if(entry.isDirectory()&&!entry.isSymbolicLink()&&/^project-[a-f0-9-]+$/.test(entry.name)){
    const machineFile=path.join(loc.state,entry.name,'machine.json');
    if(await exists(machineFile)){const machine=await readJSON(machineFile);if(machine.project===loc.project&&typeof machine.config==='string'&&path.isAbsolute(machine.config))matches.push(machine);}
  }
  if(matches.length>1)throw new FactoryError('存在多个本机绑定，请显式选择 --config-dir',3);
  if(matches.length===1)loc.config=matches[0].config;
  return loc;
}
export async function walk(root        , options      = {}) {
  const results           = [], omissions        = [];
  const ignored = new Set(['.git', 'node_modules', '.factory', '.env', 'dist', 'coverage', '.scratch', '.cache', ...(options.ignore || [])]);
  const ignoreRules        = [];
  async function visit(dir        , depth        ) {
    const ignoreFile = path.join(root, dir, '.gitignore');
    try {
      if (!(await fs.lstat(ignoreFile)).isSymbolicLink()) {
        for (const raw of (await fs.readFile(ignoreFile, 'utf8')).split('\n')) {
          const rule = raw.trim(); if (!rule || rule.startsWith('#')) continue;
          const negate = rule.startsWith('!'), pattern = (negate ? rule.slice(1) : rule).replace(/^\//, '').replace(/\/$/, '');
          ignoreRules.push({ base: dir, pattern, negate });
        }
      }
    } catch (e) { if ((e                         ).code !== 'ENOENT') omissions.push({ path: path.posix.join(dir, '.gitignore'), reason: 'ignore-unreadable' }); }
    if (depth > (options.depth ?? 6)) { omissions.push({ path: dir, reason: 'depth-limit' }); return; }
    let entries; try { entries = await fs.readdir(path.join(root, dir), { withFileTypes: true }); } catch (e) { omissions.push({ path: dir, reason: 'unreadable' }); return; }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const relative = path.posix.join(dir, entry.name);
      if (results.length >= (options.limit ?? 1500)) { omissions.push({ path: relative, reason: 'file-limit' }); break; }
      let gitIgnored = false;
      for (const rule of ignoreRules) {
        const local = path.posix.relative(rule.base || '.', relative);
        if (local.startsWith('../')) continue;
        const matches = rule.pattern.includes('/') ? path.matchesGlob(local, rule.pattern) : local.split('/').some(part => path.matchesGlob(part, rule.pattern));
        if (matches) gitIgnored = !rule.negate;
      }
      if (gitIgnored) { omissions.push({ path: relative, reason: 'gitignore' }); continue; }
      if (ignored.has(entry.name) || /^\.env(?:\.|$)|\.(pem|key)$/.test(entry.name)) { omissions.push({ path: relative, reason: 'ignored' }); continue; }
      if (entry.isSymbolicLink()) { omissions.push({ path: relative, reason: 'symlink' }); continue; }
      if (entry.isDirectory()) await visit(relative, depth + 1); else if (entry.isFile()) results.push(relative);
    }
  }
  await visit('', 0); return { files: results, omissions };
}
export async function tree(root        ) {
  const scan = await walk(root, { depth: 30, limit: 10000, ignore: [] });
  if (scan.omissions.length) throw new FactoryError('依赖快照不完整或包含不支持的链接/忽略目录', 3, scan.omissions);
  const files = [];
  for (const name of scan.files) files.push({ path: name, digest: await hashFile(await safePath(root, name)) });
  return { digest: digest(files), files };
}
export async function artifact(state        , projectId        , bytes                 ) {
  const hash = digest(bytes); const file = path.join(state, projectId, 'artifacts', hash);
  if (!(await exists(file))) await atomicWrite(file, bytes);
  return { uri: `artifact:sha256:${hash}`, digest: hash, size: Buffer.byteLength(bytes), path: file };
}
