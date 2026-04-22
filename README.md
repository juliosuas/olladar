# olladar

![license](https://img.shields.io/badge/license-MIT-blue) ![node](https://img.shields.io/badge/node-%E2%89%A522.5-brightgreen) ![ollama](https://img.shields.io/badge/ollama-%E2%89%A50.5-black) ![status](https://img.shields.io/badge/status-v0.1.0-orange)

> **ollama + radar.** Observability, tool-use acceleration, and eval harness for local LLMs running on ollama.

A transparent proxy that sits between your ollama-compatible client (OpenClaw, Open WebUI, your own agent, etc.) and the ollama server. It logs every call to SQLite, surfaces latency and tool-use metrics, and applies a targeted fix for a well-known failure mode where reasoning models silently fail to emit `tool_calls` — turning 7 s tool-use decisions into 1 s ones with zero loss of quality.

## Why it exists

Running ollama locally is great until you hit two walls:

1. **No observability.** ollama's logs tell you the model was called; they don't tell you how often, how slow, or when your agent framework is paying a tax on things that look fast in isolation. You find out tool-use is broken when your WhatsApp bot stops responding, not when it's still cheap to fix.

2. **qwen3 (and other reasoning models) silently lose tool_calls.** With `reasoning=true`, qwen3 models spend their `num_predict` budget on the `thinking` field and emit zero `tool_calls` when tools are in the request body. Accuracy drops from 100% to ~20%, latency triples, and nothing logs a failure.

olladar fixes both without asking your client to change a single line beyond the `baseUrl` it points to.

## What it does

- **Transparent pass-through proxy** on port `11435`, forwarding to ollama on `11434`. Streaming preserved, headers preserved, bodies preserved.
- **SQLite logger** at `~/.local/share/olladar/logs.sqlite` — every request/response with TTFT, tokens, tool-call emission, and full trace bodies for later analysis.
- **Automatic `think: false` injection** when a request has `tools[]` and the caller didn't set `think` — specifically fixes qwen3's silent tool-use failure. Non-tool requests keep whatever thinking configuration the client set.
- **`olladar` CLI** to inspect the log: `last`, `slow`, `failures`, `stats`, `tools`, `trace`, `size`, `watch`, `stream`.
- **Eval harness** (`eval/run.py`) with 20 curated cases across tool_use, synthesis, coding, long-context, and whatsapp-intent categories. Runnable against any ollama-compatible endpoint.

## Install

Requirements:

- **Node ≥ 22.5** (for `node:sqlite`; experimental but stable enough for this use)
- **ollama** running on `127.0.0.1:11434`
- **Python 3** (for the CLI helpers and eval harness)
- **Linux with systemd user services** (a version without systemd autostart is a simple PR away — see `bin/olladar-proxy.mjs` for the single-file binary)

```bash
git clone https://github.com/juliosuas/olladar.git
cd olladar
./install.sh
```

`install.sh` auto-detects a compatible Node (preferring `nvm` installs), copies the binaries to `~/.local/bin`, installs the systemd user unit, and starts the proxy. After install you should see:

```bash
$ olladar stats --since 1h
No calls in last 1h
```

Then point your ollama client at `http://127.0.0.1:11435` instead of `:11434`.

> **Privacy note.** olladar stores full prompt bodies in the `traces` table of its SQLite log. If you routinely paste secrets, API keys, or sensitive data into LLM prompts, know that those prompts persist on disk at `~/.local/share/olladar/logs.sqlite`. See [docs/MANUAL.md#sqlite-schema](docs/MANUAL.md#sqlite-schema) for how to opt out or purge the log.

## Quick usage

```bash
# See the last 20 requests flowing through the proxy
olladar last 20

# Aggregate stats for the last 24h grouped by model
olladar stats --since 24h

# Tool-use accuracy per model (did the model emit tool_calls when asked to?)
olladar tools --since 24h

# The slowest 10 calls (great for finding regressions)
olladar slow 10

# Live tail — watch calls stream in as they happen
olladar watch

# Send a prompt directly and watch tokens stream with a live tok/s counter
olladar stream --think off "di hola en 3 idiomas"
olladar stream --model qwen2.5-coder:7b "bash oneliner para listar top 5 procesos por RAM"
olladar stream --tools --max-tokens 200 "abre github.com"  # triggers the auto think:false path
```

## How the `think: false` injection works

When a JSON body arrives at `POST /api/chat`, olladar checks two things:

1. Is `tools[]` a non-empty array?
2. Is `think` absent from the top level?

If both are true, olladar sets `think: false` before forwarding. qwen3 interprets this as "skip the thinking phase, go straight to tool emission or content." Measured effect on a single RTX 4090 running qwen3:32b at 4K ctx:

| Metric | Default (`think` unset, reasoning on) | With olladar injection |
|---|---|---|
| Tool-use accuracy | 38 % (3/8 on eval harness) | **100 %** (8/8) |
| Tool decision avg latency | 7,192 ms | **1,323 ms** |
| Overall eval pass rate | 35 % | **70 %** |

For non-tool requests, olladar passes the body through unchanged. If your client explicitly sets `think` (to either `true` or `false`), olladar respects that.

### Reproduce the numbers

The raw eval runs are shipped in the repo:

- `eval/results/qwen3_32b-baseline.json` — same 20 cases, `think` unset, reasoning on
- `eval/results/qwen3_32b-with-olladar.json` — same 20 cases, routed through olladar's proxy

Re-run on your machine:

```bash
# Baseline: hit ollama directly
python3 eval/run.py --model qwen3:32b --endpoint http://127.0.0.1:11434

# With olladar
python3 eval/run.py --model qwen3:32b --endpoint http://127.0.0.1:11435
```

## Architecture

```
┌──────────────────┐   POST /api/chat   ┌────────────────┐   POST /api/chat   ┌──────────┐
│   OpenClaw /     │ ──────────────────▶│   olladar      │ ──────────────────▶│  ollama  │
│   Open WebUI /   │                    │   :11435       │  (with think:false │  :11434  │
│   your agent     │ ◀──────────────────│                │   injected if      │          │
│                  │   response stream  │                │   tools[] present) │          │
└──────────────────┘                    └───────┬────────┘                    └──────────┘
                                                │ request_id, ts, model,
                                                │ tokens, ttft, tool_calls,
                                                │ full body + response
                                                ▼
                                       ~/.local/share/olladar/
                                           logs.sqlite
                                              │
                                              ▼
                                       olladar {last,stats,...}
```

The proxy is ~200 lines of Node with no external runtime dependencies beyond Node 22.5's built-in `node:sqlite`.

## The eval harness

`eval/run.py` runs 20 curated prompts against any ollama-compatible endpoint and reports pass rates by category, latency percentiles, and tokens per second. Use it to compare models, validate configuration changes, or gate releases.

```bash
# default: runs against olladar proxy on :11435 (so it also captures into logs)
python3 eval/run.py --model qwen3:32b

# compare a different model
python3 eval/run.py --model qwen2.5-coder:7b

# skip the proxy and hit ollama directly (useful for A/B tests)
python3 eval/run.py --model qwen3:32b --endpoint http://127.0.0.1:11434
```

Categories:

- **tool_use** (8 cases) — ability to emit `tool_calls` when given tools
- **synthesis** (5 cases) — text responses judged by substring match
- **coding** (3 cases) — code generation
- **long_ctx** (2 cases) — retrieval/reasoning inside a ≥ 8K prompt
- **whatsapp** (2 cases) — short mobile-style intents

Output lands in `~/Desktop/llm-eval/results/` as dated JSON.

## Uninstall

```bash
./uninstall.sh          # keeps the SQLite log
./uninstall.sh --purge  # deletes logs too
```

## What's next

olladar is intentionally narrow. Things it does not try to be:

- A replacement for LiteLLM or OpenRouter. olladar is single-upstream, zero-rewrite.
- A chat UI. It's a proxy; pair it with OpenClaw / Open WebUI / your own.
- An ollama fork. It proxies upstream; no model logic lives here.

Open ideas on the roadmap (see `docs/MANUAL.md` for working notes):

- Speculative decoding pass-through when upstream ollama supports `draft_model`.
- Request-shape-aware hybrid routing (small model for tool decisions, big model for synthesis).
- A web dashboard over the SQLite log.

## License

MIT — see `LICENSE`.

## Author

Julio Suárez ([@juliosuas](https://github.com/juliosuas))

Built to stop debugging local LLM weirdness with `print()` statements.
