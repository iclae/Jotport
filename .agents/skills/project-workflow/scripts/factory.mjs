#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { workspaceContext, workspaceCheck, workspaceRecord, workspaceConsolidate } from '../runtime/workspace/index.js';
const args = process.argv.slice(2), action = args.shift() || 'context';
const options = { project: fileURLToPath(new URL('../../../../', import.meta.url)) };
let input;
try {
  for (let i = 0; i < args.length; i++) {
    const key = args[i], value = args[++i];
    if (!['--project','--task','--query','--input','--scope'].includes(key) || !value || value.startsWith('--')) throw new Error('无效参数：' + key);
    if (key === '--input') input = value; else options[key.slice(2)] = value;
  }
  let result;
  if (action === 'context') result = await workspaceContext(options);
  else if (action === 'check') result = await workspaceCheck(options);
  else if (action === 'record' || action === 'consolidate') {
    if (!input) throw new Error(action + ' 需要 --input <JSON>');
    const data = JSON.parse(await fs.readFile(path.resolve(input), 'utf8'));
    result = action === 'record' ? await workspaceRecord(data, options) : await workspaceConsolidate(data, options);
  } else throw new Error('支持 context、check、record、consolidate；流程见 .factory/workflow.md');
  console.log(JSON.stringify(result, null, 2));
  if (action === 'check' && (result.ok === false || result.valid === false)) process.exitCode = 5;
} catch (error) { console.error(JSON.stringify({ error: error.message })); process.exitCode = error.code || 1; }
