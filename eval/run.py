#!/usr/bin/env python3
"""llm-eval runner. Scores models against eval-cases.yaml.

Metrics per case:
  tool_use:   tool_call_emitted + correct tool + args substring match
  synthesis:  response contains any expected_contains term (best-effort)
  coding:     response contains key tokens (syntactic heuristic)
  long_ctx:   response contains expected answer
  whatsapp:   tool/content match

Outputs JSON summary to results/YYYY-MM-DDTHHMM-MODEL.json
Also prints per-case + aggregate to stdout.
"""
import argparse, json, sys, time, urllib.request, datetime, os, re

# Minimal YAML parser — only supports the flat structure of eval-cases.yaml
def parse_eval_yaml(path):
    import yaml
    try:
        return yaml.safe_load(open(path))
    except ImportError:
        # fall back: hand-parse (limited)
        pass
    return None

def call_ollama(model, prompt, tools=None, max_tokens=300, endpoint="http://127.0.0.1:11435"):
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": "Eres un agente útil. Cuando tengas tools disponibles para una tarea, úsalas emitiendo tool_calls. Si no, responde en texto."},
            {"role": "user", "content": prompt}
        ],
        "stream": False,
        "options": {"num_predict": max_tokens, "temperature": 0.2},
    }
    if tools:
        body["tools"] = [
            {"type": "function", "function": {
                "name": t,
                "description": {
                    "browser_open": "Abre una URL en browser stealth Chromium",
                    "shell_run": "Corre un comando bash en el host",
                    "web_fetch": "Fetch HTTP GET de una URL y devuelve el contenido",
                    "answer": "Responde en texto cuando no se necesita tool"
                }.get(t, "tool"),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "url": {"type": "string"} if t in ("browser_open", "web_fetch") else None,
                        "cmd": {"type": "string"} if t == "shell_run" else None,
                        "text": {"type": "string"} if t == "answer" else None,
                    },
                    "required": {
                        "browser_open": ["url"], "web_fetch": ["url"],
                        "shell_run": ["cmd"], "answer": ["text"]
                    }.get(t, []),
                }
            }} for t in tools
        ]
        # strip None in properties
        for f in body["tools"]:
            f["function"]["parameters"]["properties"] = {
                k: v for k, v in f["function"]["parameters"]["properties"].items() if v is not None
            }

    t0 = time.time()
    req = urllib.request.Request(
        f"{endpoint}/api/chat",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            resp = json.loads(r.read().decode())
    except Exception as e:
        return {"error": str(e), "wall_ms": (time.time()-t0)*1000}
    t1 = time.time()
    msg = resp.get("message", {})
    return {
        "wall_ms": (t1 - t0) * 1000,
        "ttft_ms": resp.get("prompt_eval_duration", 0) / 1e6,
        "content": msg.get("content", "") or "",
        "tool_calls": msg.get("tool_calls") or [],
        "eval_count": resp.get("eval_count", 0),
        "prompt_eval_count": resp.get("prompt_eval_count", 0),
    }

def score_case(case, result):
    kind = case["kind"]
    score = {"case_id": case["id"], "kind": kind, "passed": False, "notes": []}
    if "error" in result:
        score["notes"].append(f"ERROR {result['error']}")
        return score

    content = (result["content"] or "").lower()
    tool_calls = result["tool_calls"]

    if kind in ("tool_use", "whatsapp"):
        expected_tool = case.get("expected_tool")
        expected_args = case.get("expected_args_contains", [])
        if expected_tool:
            expected_tools = expected_tool if isinstance(expected_tool, list) else [expected_tool]
            # Check for structured tool_calls first
            if tool_calls:
                actual = tool_calls[0].get("function", {}).get("name", "")
                actual_args = json.dumps(tool_calls[0].get("function", {}).get("arguments", {})).lower()
                if actual in expected_tools:
                    args_ok = not expected_args or any(a.lower() in actual_args for a in expected_args)
                    score["passed"] = args_ok
                    score["notes"].append(f"tool={actual} args_ok={args_ok}")
                else:
                    score["notes"].append(f"wrong tool: {actual} (expected {expected_tools})")
            else:
                # Check if content has JSON-embedded tool emission (common for non-native models)
                m = re.search(r'"name"\s*:\s*"([a-z_]+)"', content)
                if m and m.group(1) in expected_tools:
                    score["passed"] = True
                    score["notes"].append(f"tool_as_json: {m.group(1)}")
                elif expected_tool == "answer":
                    # answer-type: just need a sensible response
                    score["passed"] = len(content.strip()) > 10
                    score["notes"].append(f"answer len={len(content)}")
                else:
                    score["notes"].append("no tool_call emitted")
        else:
            score["passed"] = len(content.strip()) > 5
            score["notes"].append(f"free-text len={len(content)}")
    elif kind in ("synthesis", "coding", "long_ctx"):
        expected = [t.lower() for t in case.get("expected_contains", [])]
        if expected:
            hits = sum(1 for t in expected if t in content)
            score["passed"] = hits >= max(1, len(expected) // 2)
            score["notes"].append(f"{hits}/{len(expected)} terms matched")
        else:
            score["passed"] = len(content) > 20
    return score

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="qwen3:32b")
    ap.add_argument("--endpoint", default="http://127.0.0.1:11435")
    ap.add_argument("--cases", default=os.path.expanduser("~/Desktop/llm-eval/eval-cases.yaml"))
    ap.add_argument("--out", default=os.path.expanduser("~/Desktop/llm-eval/results"))
    args = ap.parse_args()

    cfg = parse_eval_yaml(args.cases)
    if not cfg:
        print("ERROR: could not parse YAML. Install PyYAML: pip install pyyaml", file=sys.stderr)
        sys.exit(1)

    cases = cfg["cases"]
    results = []
    print(f"=== Evaluating {args.model} on {len(cases)} cases ===\n")
    t_total = time.time()
    for c in cases:
        tools = c.get("tools")
        res = call_ollama(args.model, c["prompt"], tools=tools, endpoint=args.endpoint)
        score = score_case(c, res)
        score["wall_ms"] = res.get("wall_ms", 0)
        score["ttft_ms"] = res.get("ttft_ms", 0)
        score["eval_count"] = res.get("eval_count", 0)
        results.append(score)
        status = "✓" if score["passed"] else "✗"
        print(f"  [{status}] {score['case_id']:<25} {c['kind']:<10} {score['wall_ms']:>7.0f}ms  {'; '.join(score['notes'])[:80]}")
    wall_total = time.time() - t_total

    # Aggregates
    by_kind = {}
    for r in results:
        k = r["kind"]
        by_kind.setdefault(k, {"n": 0, "passed": 0, "wall": 0})
        by_kind[k]["n"] += 1
        if r["passed"]: by_kind[k]["passed"] += 1
        by_kind[k]["wall"] += r["wall_ms"]

    print(f"\n=== Summary (model {args.model}, took {wall_total:.1f}s) ===")
    total_passed = sum(r["passed"] for r in results)
    total_wall = sum(r["wall_ms"] for r in results)
    print(f"Overall: {total_passed}/{len(results)} ({100*total_passed/len(results):.1f}%)  avg_wall={total_wall/len(results):.0f}ms")
    for k, s in by_kind.items():
        print(f"  {k:<12} {s['passed']}/{s['n']} ({100*s['passed']/s['n']:.0f}%)  avg_wall={s['wall']/s['n']:.0f}ms")

    # Save JSON
    os.makedirs(args.out, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y-%m-%dT%H%M")
    model_slug = args.model.replace(":", "_").replace("/", "_")
    outpath = os.path.join(args.out, f"{ts}-{model_slug}.json")
    with open(outpath, "w") as f:
        json.dump({
            "model": args.model,
            "endpoint": args.endpoint,
            "timestamp": ts,
            "total_wall_sec": wall_total,
            "overall": {"passed": total_passed, "n": len(results),
                        "rate": total_passed / len(results)},
            "by_kind": by_kind,
            "cases": results,
        }, f, indent=2)
    print(f"\nSaved: {outpath}")

if __name__ == "__main__":
    main()
