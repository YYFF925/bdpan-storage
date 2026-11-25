#!/usr/bin/env node
// Compare two `mcp-call.mjs tools` dumps (baseline vs current).
//
// usage:
//   node compare-mcp-tools.mjs <baseline.json> <current.json>
//
// stdout: one JSON object with added / removed / changed tools.
// exit: 0 = no drift, 1 = drift, 2 = usage or parse error.
//
// "changed" covers required-parameter changes, property additions/removals,
// schema changes (canonical JSON comparison) and description-only changes.
import fs from 'node:fs';

const [baselinePath, currentPath] = process.argv.slice(2);
if (!baselinePath || !currentPath) {
  console.error('usage: node compare-mcp-tools.mjs <baseline.json> <current.json>');
  process.exit(2);
}

function load(file) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    console.error(JSON.stringify({ ok: false, stage: 'read', file, error: error.message }));
    process.exit(2);
  }
  if (!parsed || !Array.isArray(parsed.tools)) {
    console.error(JSON.stringify({ ok: false, stage: 'shape', file, error: 'expected an object with a tools array' }));
    process.exit(2);
  }
  return parsed;
}

function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort().map((key) => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  }
  return JSON.stringify(value);
}

const baseline = load(baselinePath);
const current = load(currentPath);
const baseMap = new Map(baseline.tools.map((tool) => [tool.name, tool]));
const currentMap = new Map(current.tools.map((tool) => [tool.name, tool]));

const added = [...currentMap.keys()].filter((name) => !baseMap.has(name)).sort();
const removed = [...baseMap.keys()].filter((name) => !currentMap.has(name)).sort();
const changed = [];

for (const [name, before] of baseMap) {
  const after = currentMap.get(name);
  if (!after) continue;
  const fields = [];
  if ((before.description || '') !== (after.description || '')) fields.push('description');
  if (canonical(before.required || []) !== canonical(after.required || [])) fields.push('required');
  const beforeProps = new Set(before.props || []);
  const afterProps = new Set(after.props || []);
  const propsAdded = [...afterProps].filter((prop) => !beforeProps.has(prop)).sort();
  const propsRemoved = [...beforeProps].filter((prop) => !afterProps.has(prop)).sort();
  if (propsAdded.length || propsRemoved.length) fields.push('properties');
  if (canonical(before.schema || null) !== canonical(after.schema || null)) fields.push('schema');
  if (fields.length) {
    changed.push({
      name,
      fields,
      props_added: propsAdded,
      props_removed: propsRemoved,
      required_before: before.required || [],
      required_after: after.required || [],
    });
  }
}

changed.sort((a, b) => a.name.localeCompare(b.name));
const ok = added.length === 0 && removed.length === 0 && changed.length === 0;
console.log(JSON.stringify({
  ok,
  baseline: { file: baselinePath, count: baseline.tools.length, captured_at: baseline.captured_at || null },
  current: { file: currentPath, count: current.tools.length, captured_at: current.captured_at || null },
  added,
  removed,
  changed,
}, null, 2));
process.exit(ok ? 0 : 1);
