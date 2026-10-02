<div align="center">

<img src="assets/brand/logo-mark.svg" width="88" alt="OmniRoute-PS logo" />

# OmniRoute-PS

**A small, local-first OpenAI-compatible LLM router for PowerShell 7.**

**Status:** 🟡 Beta · **Version:** `0.1.0`

[Quick Start](#quick-start) · [Configuration](#configuration) · [Architecture](#architecture) · [Releases](https://github.com/styayur/OmniRoute-PS/releases) · [Issues](https://github.com/styayur/OmniRoute-PS/issues)

[![CI](https://github.com/styayur/OmniRoute-PS/actions/workflows/ci.yml/badge.svg)](https://github.com/styayur/OmniRoute-PS/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/styayur/OmniRoute-PS)](https://github.com/styayur/OmniRoute-PS/releases/latest)
[![license: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![PowerShell 7.4+](https://img.shields.io/badge/PowerShell-7.4%2B-5391FE?logo=powershell&logoColor=white)]()
[![local-first](https://img.shields.io/badge/local--first-0f172a)]()

</div>

> **OmniRoute-PS is an independent lightweight reimplementation inspired by the routing concepts of OmniRoute.**
> **It is not a drop-in rewrite of the full OmniRoute platform.**

OmniRoute-PS exposes one OpenAI-compatible endpoint on your machine and routes each
request to a configured upstream provider. It is deliberately small: PowerShell 7,
modern .NET, JSON configuration, no database, no browser UI, no Node.js, no Python,
no Electron, and no bundled provider SDKs.

## Project positioning

OmniRoute-PS is for developers who already use CLI and IDE clients that can point at an
OpenAI-compatible base URL. Typical examples include Codex, Cline, Continue, OpenCode,
and custom scripts. The router then handles model aliases, provider order, failover,
circuit breaking, and real SSE forwarding locally.

It is **not** a clone of the full OmniRoute application. The larger platform includes
Next.js, Electron, SQLite, MCP/A2A, MITM/PROXY features, quota handling, token
compression, dashboards, and many provider integrations. Those systems are intentionally
out of scope for this repository.

## Features

- `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`, and a limited
  `POST /v1/responses` compatibility layer.
- OpenAI Chat Completions formatting, including pass-through of ordinary request fields.
- True streaming SSE with `HttpCompletionOption.ResponseHeadersRead`; responses are not
  buffered before forwarding.
- OpenAI-compatible upstream providers, Anthropic Messages, Gemini `generateContent`,
  Ollama OpenAI compatibility, and custom OpenAI-compatible endpoints.
- Wildcard routes, exact routes, model aliases, and explicit `provider:model` selection.
- Priority-aware scoring, health penalties, failure penalties, and ordered fallback.
- In-process circuit breaker: `Closed`, `Open`, and `HalfOpen`.
- JSON configuration validation with environment-variable secret references.
- Structured console or JSON logs with redaction of authorization values, tokens,
  cookies, API keys, secrets, and passwords.
- No runtime npm, Python, database, browser, Electron, or third-party PowerShell module
  dependency.

## Requirements

- PowerShell `7.4` or newer.
- Windows 10/11 is the primary target. Core routing and tests are also exercised on
  Ubuntu in CI.
- Network access only for the providers you configure. Local Ollama and LM Studio setups
  do not require internet access.

## Installation

### Run from a clone

```powershell
git clone https://github.com/styayur/OmniRoute-PS.git
cd OmniRoute-PS
pwsh ./omniroute.ps1 check
```

Copy the example configuration before storing your own routes and provider choices:

```powershell
Copy-Item .\omniroute.example.json .\omniroute.json
```

`omniroute.json`, `.env`, and log files are ignored by Git. Do not put literal API keys
in JSON; use `apiKeyEnv` and set the environment variable outside the repository.

### Install to `$HOME\.omniroute`

The install script copies the repository, creates a launcher under
`$HOME\.omniroute\bin`, and makes no system-wide changes by default.

```powershell
pwsh ./scripts/install.ps1
# Optional: add $HOME\.omniroute\bin to the current user's PATH.
pwsh ./scripts/install.ps1 -AddToPath
```

Uninstall or reverse the install:

```powershell
pwsh "$HOME\.omniroute\scripts\install.ps1" -Uninstall
```

## Quick start

```powershell
# 1. Validate configuration and inspect which environment variables are missing.
pwsh ./omniroute.ps1 check

# 2. Set one or more provider keys in the current shell.
$env:OPENAI_API_KEY = '<your-key>'
$env:DEEPSEEK_API_KEY = '<your-key>'

# 3. Start the router.
pwsh ./omniroute.ps1 serve

# 4. In another terminal:
Invoke-RestMethod http://127.0.0.1:20128/health
Invoke-RestMethod http://127.0.0.1:20128/v1/models
```

Useful commands:

```powershell
pwsh ./omniroute.ps1 status -Json
pwsh ./omniroute.ps1 providers -Json
pwsh ./omniroute.ps1 models -Json
pwsh ./omniroute.ps1 test
pwsh ./omniroute.ps1 test -Live
pwsh ./omniroute.ps1 version -Json
pwsh ./omniroute.ps1 help
```

`test` validates configuration without network access by default. `test -Live`
performs provider health probes; it never prints or persists key values.

## Configuration

The default lookup order is:

1. `$env:OMNIROUTE_CONFIG`
2. `./omniroute.json`
3. `./omniroute.example.json`

`OMNIROUTE_HOST` and `OMNIROUTE_PORT` override `listen` and `port`.

Minimal example:

```json
{
  "listen": "127.0.0.1",
  "port": 20128,
  "requestTimeoutSeconds": 120,
  "retry": {
    "maxAttempts": 2,
    "baseDelayMs": 100
  },
  "circuitBreaker": {
    "failureThreshold": 3,
    "openSeconds": 30,
    "halfOpenMaxAttempts": 1
  },
  "providers": {
    "openai": {
      "type": "openai",
      "baseUrl": "https://api.openai.com/v1",
      "apiKeyEnv": "OPENAI_API_KEY",
      "priority": 100,
      "enabled": true,
      "models": ["gpt-5", "gpt-5-mini"]
    },
    "deepseek": {
      "type": "openai",
      "baseUrl": "https://api.deepseek.com/v1",
      "apiKeyEnv": "DEEPSEEK_API_KEY",
      "priority": 80,
      "enabled": true,
      "models": ["deepseek-chat", "deepseek-reasoner"]
    },
    "ollama": {
      "type": "ollama",
      "baseUrl": "http://127.0.0.1:11434/v1",
      "priority": 40,
      "enabled": true,
      "models": ["qwen3:8b"]
    }
  },
  "routes": {
    "gpt-*": ["openai", "deepseek"],
    "deepseek-*": ["deepseek", "openai"],
    "*": ["deepseek", "openai", "ollama"]
  },
  "aliases": {
    "fast": "deepseek-chat",
    "reasoning": "deepseek-reasoner",
    "local": "qwen3:8b"
  }
}
```

Important fields:

| Field | Purpose |
| --- | --- |
| `listen` | Listen address. Default `127.0.0.1`. Avoid `0.0.0.0` unless you intentionally expose the router. |
| `port` | Local HTTP port. |
| `requestTimeoutSeconds` | Default upstream timeout. Providers may override with `timeoutSeconds`. |
| `maxRequestBodyBytes` | Maximum accepted client request size. |
| `healthCacheSeconds` | How long a passive health result is trusted before retrying a provider. |
| `retry.maxAttempts` | Per-provider transport retry count for retryable failures. |
| `circuitBreaker.failureThreshold` | Consecutive failures before the circuit opens. |
| `circuitBreaker.openSeconds` | Time before an open circuit becomes half-open. |
| `fallbackOnStatus` | Upstream HTTP status codes that trigger fallback. |

Provider fields:

| Field | Purpose |
| --- | --- |
| `type` | `openai`, `custom-openai`, `ollama`, `anthropic`, or `gemini`. |
| `baseUrl` | Absolute `http` or `https` URL. Literal credentials and query strings are rejected. |
| `apiKeyEnv` | Name of the environment variable containing the key. |
| `apiKeyHeader` | Optional auth header override. Defaults are `Authorization`, `x-api-key`, or `x-goog-api-key`. |
| `apiKeyPrefix` | Optional value prefix, usually `Bearer `. |
| `priority` | Higher values are preferred before latency and failure penalties are applied. |
| `enabled` | Set to `false` to remove a provider from routing without deleting it. |
| `models` | Model IDs advertised by `GET /v1/models`. |
| `headers` | Non-sensitive static headers only. Sensitive header names are rejected. |

## OpenAI-compatible usage

### Chat Completions

```powershell
$body = @{
  model = 'reasoning'
  messages = @(
    @{ role = 'user'; content = 'Explain the difference between Open and HalfOpen.' }
  )
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Uri 'http://127.0.0.1:20128/v1/chat/completions' `
  -Method Post `
  -ContentType 'application/json' `
  -Body $body
```

Streaming:

```powershell
curl.exe -N http://127.0.0.1:20128/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{"model":"reasoning","stream":true,"messages":[{"role":"user","content":"Count to three."}]}'
```

### Responses API compatibility

The `/v1/responses` implementation is intentionally limited. It accepts `model`,
`input`, `instructions`, `stream`, `temperature`, `top_p`, `max_output_tokens`, `stop`,
`user`, and `seed`. Unsupported advanced fields return a clear `unsupported_parameter`
error instead of being silently ignored.

```powershell
Invoke-RestMethod `
  -Uri 'http://127.0.0.1:20128/v1/responses' `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"model":"reasoning","input":"Say hello in one sentence."}'
```

## Codex example

Codex supports user-level custom model providers through `~/.codex/config.toml`.
The current advanced configuration documentation is at
[developers.openai.com/codex/config-advanced](https://developers.openai.com/codex/config-advanced).

```toml
model = "gpt-5"
model_provider = "omniroute"

[model_providers.omniroute]
name = "OmniRoute-PS"
base_url = "http://127.0.0.1:20128/v1"
wire_api = "responses"
env_key = "OMNIROUTE_PS_KEY"
```

Set `OMNIROUTE_PS_KEY` to a local placeholder value. OmniRoute-PS does not require
client-side authentication in v0.1.0, but some clients require an environment-key field
to be present. Do not reuse a real upstream API key for this value.

## Other client configuration

- **Cline:** choose the OpenAI Compatible provider, set the base URL to
  `http://127.0.0.1:20128/v1`, use the model alias (for example `reasoning`) or
  `openai:gpt-5`, and use a placeholder API key if the form requires one.
- **Continue:** add an OpenAI-compatible model with `apiBase` set to
  `http://127.0.0.1:20128/v1`, `model` set to an alias or model ID, and `apiKey` set to a
  local placeholder.
- **OpenCode:** configure an OpenAI-compatible provider with the same base URL and model
  IDs. Keep provider-specific auth at OmniRoute-PS; the client-facing placeholder is
  local only.
- **Claude Code:** native Claude Code expects the Anthropic Messages API. OmniRoute-PS
  v0.1.0 does not expose an inbound `/v1/messages` facade, so native Claude Code is not a
  drop-in target yet. Use it through a client that can translate Anthropic Messages to
  OpenAI Chat Completions, or track the roadmap item for inbound Anthropic compatibility.

## Provider adapters

| Adapter | Upstream protocol | Typical use |
| --- | --- | --- |
| `openai` | OpenAI Chat Completions | OpenAI, DeepSeek, OpenRouter, Groq, Together, Mistral, and other compatible APIs. |
| `custom-openai` | OpenAI Chat Completions | LM Studio, vLLM, LocalAI, and private compatible gateways. |
| `ollama` | OpenAI compatibility endpoint | Local Ollama models through `http://127.0.0.1:11434/v1`. |
| `anthropic` | Anthropic Messages | Claude models via an Anthropic API key. |
| `gemini` | Gemini `generateContent` | Gemini models via `x-goog-api-key`. |

Adding another OpenAI-compatible provider normally requires only a new JSON provider
block. Do not add a new class or adapter for every service.

## Routing, fallback, and circuit breaking

Routing flow:

```text
model
  -> alias resolution
  -> explicit provider prefix, when present
  -> most-specific route pattern
  -> enabled and currently usable candidates
  -> score = priority - failure penalty - latency penalty - health penalty
  -> attempt in score order
  -> success, or fallback to the next candidate
```

Supported route examples:

```json
{
  "routes": {
    "gpt-*": ["openai", "deepseek"],
    "deepseek-*": ["deepseek", "openai", "ollama"],
    "*": ["deepseek", "openai", "ollama"]
  }
}
```

Fallback is attempted for timeouts, connection failures, malformed upstream responses,
HTTP `429`, and the configured `5xx` status list. HTTP `400`, `401`, and `403` are not
fallback candidates by default because retrying them usually hides a configuration or
request error.

Circuit breaker defaults:

```text
3 consecutive failures -> Open
30 seconds in Open      -> HalfOpen
one successful probe    -> Closed
failed probe            -> Open
```

Health is passive by default: successful and failed requests update provider state.
`test -Live` performs explicit probes. This avoids continuously hammering paid endpoints.

## SSE implementation

When `stream: true` is requested, OmniRoute-PS:

1. Opens the upstream response with `HttpCompletionOption.ResponseHeadersRead`.
2. Reads the upstream body incrementally with a `StreamReader`.
3. Parses `event:` and `data:` SSE fields into complete events.
4. Converts provider-native events into OpenAI-compatible chunks when needed.
5. Flushes each event to the client immediately.
6. Stops on `[DONE]`, or appends `[DONE]` when a provider stream ends without one.
7. Cancels and disposes the upstream response when the client write fails.

An upstream failure after headers have already been sent is reported as an SSE error
event; fallback is not possible once the response body has begun.

## Security

- Default bind address is `127.0.0.1`.
- Binding to `0.0.0.0` prints an explicit network-exposure warning.
- Client authentication is not implemented in v0.1.0. Do not expose the router to an
  untrusted network.
- API keys are read from environment variables named by `apiKeyEnv`.
- Literal `apiKey` properties and sensitive custom headers are rejected by configuration
  validation.
- API keys, authorization headers, cookies, tokens, secrets, passwords, and prompt bodies
  are never written to normal logs.
- Upstream URLs are restricted to absolute `http` or `https` URLs without credentials,
  query strings, or fragments.
- `file://`, malformed headers, CR/LF header injection, and oversized request bodies are
  rejected.
- Client errors and upstream errors are returned as structured JSON without PowerShell
  stack traces. `-Debug` adds diagnostic detail only to the local console.

## Testing

Run the full suite:

```powershell
Import-Module Pester
Invoke-Pester -Path .\tests -Output Detailed
```

Current test coverage includes:

- configuration parsing and validation;
- wildcard, exact, alias, explicit-provider, priority, unhealthy-provider, and fallback
  order behavior;
- circuit breaker state transitions;
- normal JSON responses;
- HTTP `429` and `500` fallback;
- timeout, malformed response, and connection-refused normalization;
- delayed SSE chunks;
- `[DONE]` forwarding;
- cancellation when the client stream write fails;
- actual HTTP startup and endpoint smoke tests.

Static analysis:

```powershell
Import-Module PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\omniroute.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

## Benchmarks

Measured on 2026-10-02 with PowerShell `7.6.5` on Windows
`10.0.26200`, using the self-contained local mock provider in
[`scripts/benchmark.ps1`](scripts/benchmark.ps1):

| Metric | Result |
| --- | ---: |
| `version` cold-start average, 5 runs | 965.9 ms |
| Routing-only average, 10,000 iterations | 0.5248 ms |
| 100 sequential local mock completions | 359.47 ms average |
| 20 parallel local mock completions | 1,997.6 ms total |
| Router idle working set after startup | 109.7 MB |
| Router loaded working set after benchmark | 109.7 MB |

These are single-machine observations, not a performance guarantee. The current server
uses a ThreadJob per accepted request; that keeps the implementation small and auditable
but adds latency and memory overhead under heavy local load.

Run the benchmark yourself:

```powershell
pwsh ./scripts/benchmark.ps1
pwsh ./scripts/benchmark.ps1 -Json
```

## Architecture

```text
omniroute.ps1
  -> Config.ps1       validate JSON, environment overrides, provider/routes/aliases
  -> Transport.ps1    shared HttpClient, retries, timeouts, cancellation, SSE streams
  -> Adapters.ps1     protocol conversion for OpenAI/Anthropic/Gemini/Ollama
  -> Health.ps1       passive health, scoring inputs, circuit breaker state
  -> Router.ps1       model resolution, candidate scoring, fallback, stream handling
  -> Server.ps1       HttpListener, request limits, endpoint dispatch, response flushing
  -> Logging.ps1      redacted console and JSON logs
```

The router state is process-local and resets on restart. There is no database and no
cross-process coordination.

## Limitations

- OpenAI Responses API support is intentionally limited to the documented fields.
- Native inbound Anthropic Messages compatibility (`/v1/messages`) is not included yet;
  Anthropic is supported only as an upstream provider.
- Tool/function calls are passed through for OpenAI-family providers but are not fully
  translated for Anthropic, Gemini, or Ollama.
- Streaming fallback cannot happen after response headers are sent.
- Health and circuit state are local to one process and reset on restart.
- No client authentication, accounts, quotas, dashboards, MCP, MITM, proxy mode, or
  multi-user management.
- The current ThreadJob-per-request server is optimized for clarity and local use, not
  high-concurrency production traffic.
- The measured idle working set is above the project's aspirational 80 MB target because
  of the PowerShell runtime and per-request runspaces.

## Roadmap

### Current

- Stable local OpenAI-compatible routing, fallback, circuit breaking, and SSE.
- Cross-platform CI and a small auditable PowerShell codebase.

### Next

- Add an inbound Anthropic Messages facade for native Claude Code compatibility.
- Replace one ThreadJob per request with a bounded reusable worker pool.
- Broaden OpenAI Responses API coverage and adapter tool-call translation.
- Add configuration-schema documentation and more provider-specific examples.

### Future

- Optional Windows service integration.
- Metrics suitable for local observability without a telemetry SaaS dependency.

### Not planned

- Web dashboard, database, MCP server, MITM/TPROXY, browser automation, RAG, vector DB,
  token compression, account system, or mandatory Docker deployment.

## License

OmniRoute-PS is licensed under the [Apache License 2.0](LICENSE), following the
Stya Yur Open Source Studio license policy for developer infrastructure and integration
runtimes.

OmniRoute is [diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute),
licensed under MIT. OmniRoute-PS is a clean-room implementation inspired by its unified
routing concept; no OmniRoute source code has been copied into this repository. Provider
names, APIs, and services remain the property of their respective owners. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Community

Use GitHub Issues for reproducible bugs and scoped feature requests. Security issues
should use GitHub private vulnerability reporting rather than a public issue.
