# Running Debrief with a local LLM

Debrief's coaching step normally calls the Claude API. If you'd rather keep
everything on your machine (or use another provider), point Debrief at any
OpenAI-compatible server. This guide uses Ollama; LM Studio and remote
providers are covered at the end.

## Honest expectations

Local models produce noticeably weaker coaching than Claude: shallower
feedback, occasional invented quotes, and (rarely) malformed output. When
output can't be parsed the session shows **failed** — use "Retry pending
debriefs" in Settings or "Generate debrief" on the failed session. A 14B-class
model is the practical floor for useful feedback.

## 1. Install Ollama and pull a model

```sh
brew install ollama
ollama serve   # leave running (or: brew services start ollama)
```

Pick by RAM (unified memory):
| Mac RAM | Model | Pull command |
|---|---|---|
| 16 GB | `qwen2.5:14b` | `ollama pull qwen2.5:14b` |
| 32 GB | `deepseek-r1:32b` or `qwen2.5:32b` | `ollama pull deepseek-r1:32b` |
| 64 GB+ | `llama3.3:70b` | `ollama pull llama3.3:70b` |

Instruction-tuned models that follow JSON format requests work best.

## 2. Raise the context window (IMPORTANT)

Ollama defaults to a small context window (4k tokens for many models) and
**silently truncates** anything longer. A 45-minute interview transcript plus
the coaching rubric is far bigger than that — with the default you'd get a
debrief of the first few minutes only, with no error.

```sh
OLLAMA_CONTEXT_LENGTH=32768 ollama serve
```

(Or set it in the Ollama app's settings, or bake `PARAMETER num_ctx 32768`
into a Modelfile.) Rule of thumb: 1 hour of interview ≈ 12-16k tokens; 32k
covers any realistic session. To confirm truncation isn't happening, run
`ollama ps` during a debrief and check the context size it reports.

## 3. Point Debrief at it

Settings → Coaching model → Provider: **Local / OpenAI-compatible**
- Base URL: `http://localhost:11434/v1`
- Model: the tag you pulled, e.g. `qwen2.5:14b`
- API key: leave empty for Ollama

The next debrief (or a retry of a failed one) uses the local model.

## Variants

**LM Studio:** load a model, enable the local server (default
`http://localhost:1234/v1`), use the model name shown in the server tab.
Set the context length in the model load settings — same truncation warning
applies.

**Remote OpenAI-compatible providers (e.g. DeepSeek cloud):** Base URL
`https://api.deepseek.com/v1`, model `deepseek-chat`, and paste the
provider's API key into the API key field. Note: your transcript leaves your
machine, same as with Claude.

## Troubleshooting

- **Session failed immediately** — is the server running? `curl http://localhost:11434/v1/models` should return JSON.
- **Failed after several minutes** — the model likely produced unparseable output; retry, or switch to a larger/instruction-tuned model.
- **Debrief only covers the start of the interview** — context window too small; see step 2.
- **HTTP 404** — Base URL must include `/v1`.
