#!/usr/bin/env node
// Minimal MCP client for the HTTP+SSE transport, used only for maintenance checks
// against the official Baidu Netdisk MCP Server. The access token comes from the
// MCP_TOKEN environment variable or a token file, so it never appears on a command
// line, in the output, or in an error message.
//
// The server intermittently accepts a new session's `initialize` and then never answers it.
// Each session therefore gets a short initialize timeout and a failed attempt is replaced by
// a fresh session. Once a session is established its calls run normally, and `batch` runs
// many calls inside one session instead of opening one session per call.
//
// usage: node mcp-call.mjs <token-file> handshake
//        node mcp-call.mjs <token-file> tools
//        node mcp-call.mjs <token-file> call <tool> [json-arguments]
//        node mcp-call.mjs <token-file> batch <file.json>     (array of {tool, args, pauseMs})
//
//        MCP_TOKEN='<token>' node mcp-call.mjs handshake      (token from environment)
//        MCP_TOKEN='<token>' node mcp-call.mjs tools
//
// stdout carries the server payload; stderr carries status lines. Set MCP_DEBUG=1 for
// transport-level progress on stderr (never the token).
import fs from 'node:fs';

const START = Date.now();
const args = process.argv.slice(2);
const MODES = new Set(['handshake', 'tools', 'call', 'batch']);
let tokenFile = null;
if (args.length && !MODES.has(args[0])) tokenFile = args.shift();
const [mode = 'handshake', toolName, argsJson = '{}'] = args;
if (!tokenFile && !process.env.MCP_TOKEN) {
  console.error(JSON.stringify({ ok: false, stage: 'args', error: 'usage: mcp-call.mjs <token-file> <mode> ... or set MCP_TOKEN and omit the token file' }));
  process.exit(2);
}

const extractToken = (raw) => {
  const firstLine = (String(raw).match(/\S[^\r\n]*/g) || [''])[0];
  const fromUrl = firstLine.match(/access_token=([^&\s]+)/);
  return (fromUrl ? fromUrl[1] : firstLine).trim();
};

let token = process.env.MCP_TOKEN ? extractToken(process.env.MCP_TOKEN) : '';
if (!token && tokenFile) token = extractToken(fs.readFileSync(tokenFile, 'utf8'));
if (!token || /\s/.test(token)) {
  console.error(JSON.stringify({ ok: false, stage: 'token', error: 'the token is empty or contains whitespace (use a raw token or the login_success URL)' }));
  process.exit(2);
}

const BASE = 'https://mcp-pan.baidu.com';
const auth = { Authorization: 'Bearer ' + token };
const postHeaders = { ...auth, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' };
const REPLY_TIMEOUT = Number(process.env.MCP_REPLY_TIMEOUT_MS) || 60000;
const INIT_TIMEOUT = Number(process.env.MCP_INIT_TIMEOUT_MS) || 8000;
const SESSION_ATTEMPTS = Number(process.env.MCP_SESSION_ATTEMPTS) || 12;

// Never let the token leak through an error message or a debug line.
const scrub = (value) => String(value).split(token).join('<token>');
const debug = (message) => { if (process.env.MCP_DEBUG) console.error('[mcp] ' + scrub(message)); };
const withTimeout = (promise, ms, label) =>
  Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error('timeout waiting for ' + label)), ms))]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// One MCP session over HTTP+SSE. All state lives in this closure, so a failed attempt can be
// abandoned with abort() without touching the next attempt.
function openSession() {
  const ctrl = new AbortController();
  const pending = new Map(); // json-rpc id -> { resolve, reject }
  let nextId = 1;
  let endpoint = null;
  let announceEndpoint;
  const endpointReady = new Promise((resolve) => { announceEndpoint = resolve; });
  let lastEvent = '';

  const post = (payload) => fetch(new URL(endpoint, BASE), { method: 'POST', headers: postHeaders, body: JSON.stringify(payload), signal: ctrl.signal });

  // Answer a server-to-client request (the server sends `ping` keep-alives).
  async function reply(id, method) {
    if (!endpoint) return;
    const payload = method === 'ping'
      ? { jsonrpc: '2.0', id, result: {} }
      : { jsonrpc: '2.0', id, error: { code: -32601, message: 'method not found: ' + method } };
    try {
      await post(payload);
    } catch {
      // best effort: a dropped keep-alive answer only risks an idle disconnect
    }
  }

  async function readSse(response) {
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let newline;
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline).replace(/\r$/, '');
          buffer = buffer.slice(newline + 1);
          if (line === '') { lastEvent = ''; continue; } // end of event: reset
          if (line.startsWith(':')) continue; // comment / keep-alive
          if (line.startsWith('event:')) { lastEvent = line.slice(6).trim(); continue; }
          if (!line.startsWith('data:')) continue;
          const data = line.slice(5).trim();
          if (!endpoint && /endpoint/i.test(lastEvent)) { endpoint = data; announceEndpoint(); continue; }
          let message = null;
          try { message = JSON.parse(data); } catch { continue; }
          if (!message || typeof message !== 'object') continue;
          // A message that carries a method is a server request (e.g. ping) or notification, never a reply.
          if (message.method !== undefined) {
            debug('server request on stream: ' + message.method);
            if (message.id !== undefined) reply(message.id, message.method);
            continue;
          }
          const waiter = message.id !== undefined ? pending.get(message.id) : null;
          if (waiter) { pending.delete(message.id); waiter.resolve(message); }
        }
      }
    } catch {
      // stream closed or aborted; fall through to fail the pending calls
    }
    for (const waiter of pending.values()) waiter.reject(new Error('sse stream closed'));
    pending.clear();
  }

  async function send(method, params, timeout, notification = false) {
    // String ids cannot collide with the numeric ids the server uses for its own requests.
    const id = 'c' + nextId++;
    const payload = { jsonrpc: '2.0', method, ...(params !== undefined ? { params } : {}) };
    if (!notification) payload.id = id;
    let response;
    try {
      response = await post(payload);
    } catch (error) {
      throw new Error('POST ' + method + ' failed: ' + scrub(error.message));
    }
    const text = await response.text().catch(() => '');
    debug('POST ' + method + ' -> http ' + response.status + ', body ' + text.length + ' chars');
    if (notification) return { http: response.status };

    // The reply arrives either in the POST body or on the SSE stream.
    let fromBody = null;
    if (text) { try { fromBody = JSON.parse(text); } catch { fromBody = null; } }
    if (fromBody && fromBody.id === id) return fromBody;
    if (response.status >= 400) throw new Error('POST ' + method + ' http ' + response.status + ' ' + scrub(text.slice(0, 200)));
    const viaStream = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    try {
      return await withTimeout(viaStream, timeout, 'reply to ' + method);
    } finally {
      pending.delete(id);
    }
  }

  return {
    send,
    abort() { ctrl.abort(); },
    async initialize() {
      const stream = await fetch(BASE + '/sse', { headers: { ...auth, Accept: 'text/event-stream' }, signal: ctrl.signal });
      if (!stream.ok) {
        const body = await stream.text().catch(() => '');
        const error = new Error('sse http ' + stream.status + ' ' + scrub(body.slice(0, 200)));
        error.fatal = true; // an rejected token will not get better by retrying
        throw error;
      }
      readSse(stream);
      await withTimeout(endpointReady, INIT_TIMEOUT, 'endpoint event');
      const init = await send('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'zcode-baseline-check', version: '0.3' },
      }, INIT_TIMEOUT);
      if (!init.result) {
        const error = new Error('initialize rejected: ' + scrub(JSON.stringify(init.error || init)));
        error.fatal = true;
        throw error;
      }
      await send('notifications/initialized', undefined, INIT_TIMEOUT, true);
      const server = init.result.serverInfo || {};
      return { name: server.name, version: server.version, protocolVersion: init.result.protocolVersion };
    },
  };
}

async function connect() {
  let lastError = null;
  for (let attempt = 1; attempt <= SESSION_ATTEMPTS; attempt++) {
    const candidate = openSession();
    try {
      const server = await candidate.initialize();
      debug('session established on attempt ' + attempt);
      return { session: candidate, server, attempts: attempt };
    } catch (error) {
      candidate.abort();
      lastError = error;
      debug('session attempt ' + attempt + ' failed: ' + error.message);
      if (error.fatal || attempt === SESSION_ATTEMPTS) break;
      await sleep(2500);
    }
  }
  return { session: null, attempts: SESSION_ATTEMPTS, error: scrub(lastError ? lastError.message : 'unknown') };
}

function textOf(result) {
  return (result.content || []).filter((part) => part.type === 'text').map((part) => part.text).join('\n');
}

async function callTool(session, name, arguments_) {
  const called = await session.send('tools/call', { name, arguments: arguments_ }, REPLY_TIMEOUT);
  if (!called.result) return { tool: name, ok: false, isError: false, rpcError: called.error || called, payload: null, raw: '' };
  const result = called.result;
  const text = textOf(result);
  let payload = null;
  try { payload = JSON.parse(text); } catch { payload = null; }
  return { tool: name, ok: !result.isError, isError: !!result.isError, rpcError: null, payload, raw: payload ? undefined : text };
}

async function main() {
  const { session, server, attempts, error } = await connect();
  if (!session) return { ok: false, stage: 'session', attempts, error };
  const info = { ...server, attempts };
  try {
    if (mode === 'handshake') return { ok: true, stage: 'handshake', server: info };

    if (mode === 'tools') {
      const listed = await session.send('tools/list', {}, REPLY_TIMEOUT);
      if (!listed.result) return { ok: false, stage: 'tools/list', error: listed.error || listed };
      const tools = (listed.result.tools || []).map((tool) => ({
        name: tool.name,
        description: tool.description,
        required: tool.inputSchema && tool.inputSchema.required,
        props: Object.keys((tool.inputSchema && tool.inputSchema.properties) || {}),
        schema: tool.inputSchema,
      }));
      return { ok: true, stage: 'tools', server: info, count: tools.length, tools };
    }

    if (mode === 'call') {
      if (!toolName) return { ok: false, stage: 'args', error: 'call needs a tool name' };
      let arguments_;
      try { arguments_ = JSON.parse(argsJson); } catch (parseError) { return { ok: false, stage: 'args', error: 'arguments are not valid JSON: ' + parseError.message }; }
      return { ok: true, stage: 'calls', results: [await callTool(session, toolName, arguments_)] };
    }

    if (mode === 'batch') {
      let calls;
      try { calls = JSON.parse(fs.readFileSync(toolName, 'utf8')); } catch (readError) { return { ok: false, stage: 'args', error: 'batch file unreadable or not JSON: ' + readError.message }; }
      if (!Array.isArray(calls)) return { ok: false, stage: 'args', error: 'batch file must be a JSON array of {tool, args, pauseMs}' };
      const results = [];
      for (const call of calls) {
        try {
          results.push(await callTool(session, call.tool, call.args || {}));
        } catch (callError) {
          results.push({ tool: call.tool, ok: false, isError: false, rpcError: scrub(callError.message), payload: null, raw: '' });
        }
        if (call.pauseMs) await sleep(call.pauseMs);
      }
      return { ok: results.every((result) => result.ok), stage: 'calls', results, attempts };
    }
    return { ok: false, stage: 'args', error: 'unknown mode ' + mode };
  } finally {
    session.abort();
  }
}

let outcome;
try {
  outcome = await main();
} catch (error) {
  outcome = { ok: false, stage: 'client', error: scrub(error.message) };
}

if (outcome && outcome.stage === 'calls') {
  // One JSON line per tool call; `payload` is the server payload already parsed when it is JSON.
  for (const result of outcome.results) process.stdout.write(JSON.stringify(result) + '\n');
  process.exitCode = outcome.ok ? 0 : 1;
} else {
  process.stdout.write(JSON.stringify(outcome, null, 1) + '\n');
  process.exitCode = outcome && outcome.ok ? 0 : 1;
}
if (process.env.MCP_DEBUG) console.error('[mcp] done in ' + (Date.now() - START) + ' ms');
setTimeout(() => process.exit(process.exitCode || 0), 200);
