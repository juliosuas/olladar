#!/usr/bin/env node
// olladar-proxy — transparent logging proxy for ollama.
// Listens :11435, forwards to :11434. Logs to ~/.local/share/olladar/logs.sqlite.

import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const UPSTREAM = {
  host: process.env.OLLADAR_UPSTREAM_HOST || '127.0.0.1',
  port: parseInt(process.env.OLLADAR_UPSTREAM_PORT || '11434', 10),
};
const LISTEN_PORT = parseInt(process.env.OLLADAR_LISTEN_PORT || '11435', 10);

const DB_DIR = path.join(homedir(), '.local/share/olladar');
mkdirSync(DB_DIR, { recursive: true });
const DB_PATH = path.join(DB_DIR, 'logs.sqlite');

const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;');
db.exec(`
  CREATE TABLE IF NOT EXISTS calls (
    request_id       TEXT PRIMARY KEY,
    ts               INTEGER NOT NULL,
    endpoint         TEXT NOT NULL,
    model_requested  TEXT,
    model_served     TEXT,
    had_tools        INTEGER NOT NULL DEFAULT 0,
    tool_call_emitted INTEGER NOT NULL DEFAULT 0,
    stream           INTEGER NOT NULL DEFAULT 0,
    ttft_ms          REAL,
    total_ms         REAL,
    prompt_tokens    INTEGER,
    completion_tokens INTEGER,
    fallback_used    INTEGER NOT NULL DEFAULT 0,
    status_code      INTEGER,
    error            TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts);
  CREATE INDEX IF NOT EXISTS idx_calls_model ON calls(model_served);

  CREATE TABLE IF NOT EXISTS traces (
    request_id    TEXT PRIMARY KEY,
    ts            INTEGER NOT NULL,
    messages_json TEXT,
    tools_json    TEXT,
    response_json TEXT
  );
`);

const insertCall = db.prepare(`
  INSERT INTO calls (request_id, ts, endpoint, model_requested, had_tools, stream)
  VALUES (?, ?, ?, ?, ?, ?)
`);
const updateCall = db.prepare(`
  UPDATE calls SET model_served = ?, tool_call_emitted = ?, ttft_ms = ?, total_ms = ?,
    prompt_tokens = ?, completion_tokens = ?, status_code = ?, error = ?
  WHERE request_id = ?
`);
const insertTrace = db.prepare(`
  INSERT INTO traces (request_id, ts, messages_json, tools_json, response_json)
  VALUES (?, ?, ?, ?, ?)
`);

function parseJsonSafe(buf) {
  try { return JSON.parse(buf); } catch { return null; }
}

function extractMetrics(respObj) {
  if (!respObj) return {};
  const msg = respObj.message ?? respObj.choices?.[0]?.message ?? {};
  const toolCalls = msg.tool_calls ?? respObj.choices?.[0]?.message?.tool_calls ?? null;
  return {
    model_served: respObj.model ?? null,
    prompt_tokens: respObj.prompt_eval_count ?? respObj.usage?.prompt_tokens ?? null,
    completion_tokens: respObj.eval_count ?? respObj.usage?.completion_tokens ?? null,
    tool_call_emitted: Array.isArray(toolCalls) && toolCalls.length > 0 ? 1 : 0,
  };
}

const server = http.createServer((req, res) => {
  const requestId = randomUUID();
  const tStart = Date.now();
  const tStartHr = process.hrtime.bigint();

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const bodyBuf = Buffer.concat(chunks);
    const bodyText = bodyBuf.toString('utf8');
    const bodyObj = parseJsonSafe(bodyText);
    const modelReq = bodyObj?.model ?? null;
    const hadTools = Array.isArray(bodyObj?.tools) && bodyObj.tools.length > 0 ? 1 : 0;
    const isStream = bodyObj?.stream === true ? 1 : 0;
    const endpoint = req.url || '';

    // Fase 4: inject think:false when tools are present and caller didn't set it.
    // qwen3 reasoning models burn num_predict on thinking and don't emit tool_calls.
    // think:false is 7-8x faster AND correctly emits tool_calls.
    let forwardBodyBuf = bodyBuf;
    let thinkInjected = false;
    if (hadTools && bodyObj && bodyObj.think === undefined) {
      bodyObj.think = false;
      thinkInjected = true;
      forwardBodyBuf = Buffer.from(JSON.stringify(bodyObj));
    }

    try { insertCall.run(requestId, tStart, endpoint, modelReq, hadTools, isStream); }
    catch (e) { console.error('[olladar] insert:', e.message); }

    // Strip hop-by-hop / body-encoding headers that would mis-frame the forwarded body.
    // We always send a plain-text body with an explicit content-length.
    const fwdHeaders = { ...req.headers };
    delete fwdHeaders['content-encoding'];
    delete fwdHeaders['transfer-encoding'];
    delete fwdHeaders['connection'];
    fwdHeaders['host'] = `${UPSTREAM.host}:${UPSTREAM.port}`;
    fwdHeaders['content-length'] = forwardBodyBuf.length;

    const proxyReq = http.request({
      host: UPSTREAM.host, port: UPSTREAM.port,
      method: req.method, path: endpoint,
      headers: fwdHeaders,
    }, (proxyRes) => {
      res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers);

      let firstChunkAt = null;
      let respBytes = 0;
      const RESP_CAP = 512 * 1024;  // keep at most 512 KB for post-hoc parsing
      const respChunks = [];
      let respTruncated = false;
      proxyRes.on('data', (chunk) => {
        if (firstChunkAt === null) firstChunkAt = process.hrtime.bigint();
        if (respBytes < RESP_CAP) {
          respChunks.push(chunk);
          respBytes += chunk.length;
          if (respBytes >= RESP_CAP) respTruncated = true;
        }
        res.write(chunk);  // always pass through to client
      });
      proxyRes.on('end', () => {
        res.end();
        const tEnd = process.hrtime.bigint();
        const total_ms = Number(tEnd - tStartHr) / 1e6;
        const ttft_ms = firstChunkAt ? Number(firstChunkAt - tStartHr) / 1e6 : null;

        const respText = Buffer.concat(respChunks).toString('utf8');
        let respObj = parseJsonSafe(respText);
        if (!respObj && isStream) {
          const lines = respText.trim().split(/\r?\n/).filter(Boolean);
          for (let i = lines.length - 1; i >= 0; i--) {
            respObj = parseJsonSafe(lines[i]);
            if (respObj) break;
          }
        }
        const metrics = extractMetrics(respObj);

        try {
          updateCall.run(
            metrics.model_served ?? modelReq,
            metrics.tool_call_emitted ?? 0,
            ttft_ms, total_ms,
            metrics.prompt_tokens, metrics.completion_tokens,
            proxyRes.statusCode ?? 0, null, requestId
          );
          const messagesJson = bodyObj?.messages ? JSON.stringify(bodyObj.messages) : null;
          const toolsJson = bodyObj?.tools ? JSON.stringify(bodyObj.tools) : null;
          const responseJson = respObj ? JSON.stringify(respObj) : respText.slice(0, 50000);
          if ((messagesJson?.length ?? 0) < 500000) {
            insertTrace.run(requestId, tStart, messagesJson, toolsJson, responseJson);
          } else {
            // Too large to keep raw — insert a sentinel so `olladar trace` can explain.
            const sentinel = JSON.stringify({__skipped__: true, reason: 'messages_over_500kb', bytes: messagesJson.length});
            insertTrace.run(requestId, tStart, sentinel, toolsJson, responseJson?.slice(0, 10000));
          }
        } catch (e) { console.error('[olladar] update:', e.message); }
      });
      proxyRes.on('error', (e) => {
        try { updateCall.run(null, 0, null, null, null, null, 502, e.message, requestId); } catch {}
      });
    });

    proxyReq.setTimeout(600000, () => {
      proxyReq.destroy(new Error('upstream timeout after 600s'));
    });

    proxyReq.on('error', (e) => {
      try { updateCall.run(null, 0, null, null, null, null, 502, e.message, requestId); } catch {}
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
      res.end(`upstream: ${e.message}`);
    });

    proxyReq.write(forwardBodyBuf);
    proxyReq.end();
  });

  req.on('error', (e) => {
    try { updateCall.run(null, 0, null, null, null, null, 400, e.message, requestId); } catch {}
    if (!res.headersSent) res.writeHead(400, { 'content-type': 'text/plain' });
    res.end(`req: ${e.message}`);
  });
});

server.listen(LISTEN_PORT, '127.0.0.1', () => {
  console.log(`[olladar] proxy :${LISTEN_PORT} -> ollama :${UPSTREAM.port}`);
  console.log(`[olladar] db=${DB_PATH}`);
  console.log('[olladar] NOTE: traces table stores full prompt bodies (may contain secrets pasted by users)');
});

process.on('SIGTERM', () => server.close(() => { db.close(); process.exit(0); }));
process.on('SIGINT', () => server.close(() => { db.close(); process.exit(0); }));
