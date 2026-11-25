#!/usr/bin/env node
// Scrape the Baidu Netdisk open-platform documentation (pan.baidu.com/union/doc)
// into flat markdown files for review, diffing or WeKnora ingestion.
//
// usage:
//   node scrape-union-docs.mjs <out-dir> [--concurrency 6]
//
// How it works:
//   1. GET https://pan.baidu.com/union/doc/ and collect every /union/doc/... link;
//   2. each page is available as markdown by appending .md to its URL;
//   3. files are named "栏目__子栏__页面.md" to avoid collisions;
//   4. a "栏目路径 / 抓取时间" line is inserted after the first heading.
//
// Only public documentation is fetched. No credentials are used or needed.
import fs from 'node:fs';
import path from 'node:path';

const BASE = 'https://pan.baidu.com';
const INDEX = BASE + '/union/doc/';
const [outDir, ...rest] = process.argv.slice(2);
if (!outDir) {
  console.error('usage: node scrape-union-docs.mjs <out-dir> [--concurrency 6]');
  process.exit(2);
}
let concurrency = 6;
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === '--concurrency') concurrency = Math.max(1, Number(rest[i + 1]) || 6);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const decode = (value) => value.replace(/&amp;/g, '&').replace(/&#x2F;/g, '/').replace(/&quot;/g, '"');

async function fetchText(url, attempts = 3) {
  let lastError = null;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const response = await fetch(url, {
        headers: { Accept: 'text/html,text/markdown,text/plain,*/*' },
        signal: AbortSignal.timeout(30000),
      });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return await response.text();
    } catch (error) {
      lastError = error;
      if (attempt < attempts) await sleep(500 * attempt);
    }
  }
  throw lastError;
}

function linksFromHtml(html) {
  const found = new Set();
  for (const match of html.matchAll(/href\s*=\s*["']([^"']+)["']/gi)) {
    let href = decode(match[1]);
    if (/^https?:\/\//i.test(href)) {
      try { href = new URL(href).pathname; } catch { continue; }
    }
    if (!href.startsWith('/union/doc/')) continue;
    href = href.split('#')[0].split('?')[0];
    if (href === '/union/doc' || href === '/union/doc/') continue;
    href = href.replace(/\/+$/, '');
    if (href === '/union/doc') continue;
    if (/\.(png|jpe?g|gif|svg|webp|css|js|json|ico|pdf|zip|xml)$/i.test(href)) continue;
    found.add(href);
  }
  return [...found].sort();
}

function flatName(docPath) {
  let relative;
  try { relative = decodeURIComponent(docPath); } catch { relative = docPath; }
  relative = relative.replace(/^\/union\/doc\//, '').replace(/^\/+/, '');
  let name = relative.replace(/\//g, '__').replace(/[<>:"|?*\u0000-\u001f]/g, '_');
  if (!/\.md$/i.test(name)) name += '.md';
  if (name === 'index.md') name = '_index.md';
  return name;
}

function injectNote(markdown, docPath, capturedAt) {
  let relative;
  try { relative = decodeURIComponent(docPath); } catch { relative = docPath; }
  const segments = relative.replace(/^\/union\/doc\//, '').split('/').filter(Boolean);
  segments.pop(); // file name
  const section = segments.length ? segments.join(' / ') : '根';
  const note = '> 栏目路径：' + section + '　|　抓取时间：' + capturedAt;
  const lines = markdown.split('\n');
  const heading = lines.findIndex((line) => /^#\s+/.test(line));
  if (heading >= 0) lines.splice(heading + 1, 0, '', note);
  else lines.unshift(note, '');
  return lines.join('\n');
}

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  const html = await fetchText(INDEX);
  const links = linksFromHtml(html);
  if (!links.length) throw new Error('no /union/doc/ links found on the index page');
  // Encoding variants can point at the same page; dedupe by the output file name.
  const unique = new Map();
  for (const href of links) unique.set(flatName(href), href);
  const pages = [...unique.values()];
  const capturedAt = new Date().toISOString().slice(0, 10);

  const failed = [];
  let done = 0;
  let cursor = 0;

  async function worker() {
    for (;;) {
      const index = cursor++;
      if (index >= pages.length) return;
      const docPath = pages[index];
      const url = BASE + docPath + (/\.md$/i.test(docPath) ? '' : '.md');
      const file = path.join(outDir, flatName(docPath));
      try {
        const markdown = await fetchText(url);
        fs.writeFileSync(file, injectNote(markdown, docPath, capturedAt), 'utf8');
        done++;
      } catch (error) {
        failed.push({ path: docPath, error: error.message });
      }
    }
  }

  const started = Date.now();
  await Promise.all(Array.from({ length: Math.min(concurrency, pages.length) }, worker));
  const summary = {
    ok: failed.length === 0,
    out_dir: outDir,
    captured_at: capturedAt,
    pages: pages.length,
    written: done,
    failed,
    elapsed_ms: Date.now() - started,
  };
  console.log(JSON.stringify(summary, null, 2));
  process.exit(failed.length ? 1 : 0);
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error.message }));
  process.exit(1);
});
