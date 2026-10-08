# OmniRoute-PS

**A small, local-first OpenAI-compatible LLM router for PowerShell 7.**

**Status:** 🟡 Beta · **Version:** `0.2.0`

[Quick Start](#quick-start) · [Configuration](#configuration) · [Architecture](#architecture) · [Releases](https://github.com/styayur/OmniRoute-PS/releases) · [Issues](https://github.com/styayur/OmniRoute-PS/issues)

[![CI](https://github.com/styayur/OmniRoute-PS/actions/workflows/ci.yml/badge.svg)](https://github.com/styayur/OmniRoute-PS/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/styayur/OmniRoute-PS)](https://github.com/styayur/OmniRoute-PS/releases/latest)
[![license: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)


> **OmniRoute-PS is an independent lightweight reimplementation inspired by the routing concepts of OmniRoute.**
> **It is not a drop-in rewrite of the full OmniRoute platform.**

OmniRoute-PS exposes one OpenAI-compatible endpoint on your machine and routes each
request to a configured upstream provider. It is deliberately small: PowerShell 7,
modern .NET, JSON configuration, no database, no browser UI, no Node.js, no Python,
no Electron, and no bundled provider SDKs.

## Project positioning

### Checked configuration example

From the repository root:

```powershell
pwsh ./omniroute.ps1 check -ConfigPath ./omniroute.example.json
```

Actual output excerpt captured on 2026-10-08 (checkout path and provider warnings
omitted; no provider request was made):

```text
valid     : True
errors    : {}
providers : 6
routes    : 6
aliases   : 3
```

The example warns that external provider credentials are unset. This verifies
configuration parsing; it does not demonstrate authenticated inference.

OmniRoute-PS is for developers who already use CLI and IDE clients that can point at an
OpenAI-compatible base URL. Typical examples include Codex, Cline, Continue, OpenCode,
and custom scripts. The router then handles model aliases, provider order, failover,
circuit breaking, and real SSE forwarding locally.

It is **not** a clone of the full OmniRoute application. The larger platform includes
Next.js, Electron, SQLite, MCP/A2A, MITM/PROXY features, quota handling, token
compression, dashboards, and many provider integrations. Those systems are intentionally
out of scope for this repository.

## Features

- OpenAI-compatible `GET /v1/models`, `POST /v1/chat/completions`, and limited
  `POST /v1/responses`.
- Native Anthropic `POST /v1/messages`, including streaming SSE for Claude Code.
- Canonical Protocol IR shared by OpenAI Chat Completions, OpenAI Responses, and
  Anthropic Messages.
- Cross-protocol tools for OpenAI, Anthropic, and Gemini core paths.
- OpenAI-compatible upstream providers, Anthropic Messages, Gemini `generateContent`,
  Ollama OpenAI compatibility, and custom OpenAI-compatible endpoints.
- Wildcard routes, exact routes, model aliases, and explicit `provider:model` selection.
- Capability-aware routing for protocol, tools, vision, and streaming support.
- Priority-aware scoring, refined availability/latency/rate-limit/failure penalties, and
  ordered fallback.
- In-process circuit breaker: `Closed`, `Open`, and `HalfOpen`.
- Reusable `RunspacePool` workers with bounded queueing and `503` overload behavior.
- `GET /health`, `GET /health/live`, `GET /health/ready`, and Prometheus-compatible
  `GET /metrics`.
- Atomic config hot reload with debounce; invalid reloads retain the last valid config.
- CORS disabled by default and restricted to an explicit allowlist when enabled.
- JSON Schema for editor completion and validation.
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

The JSON Schema is [schemas/omniroute.schema.json](schemas/omniroute.schema.json).
Editors can use it for completion and validation.

```powershell
pwsh ./omniroute.ps1 config schema
pwsh ./omniroute.ps1 config validate
```

Minimal example:

```json
{
  "listen": "127.0.0.1",
  "port": 20128,
  "requestTimeoutSeconds": 120,
  "server": {
    "minWorkers": 2,
    "maxWorkers": 8,
    "maxQueuedRequests": 64,
    "shutdownGraceSeconds": 5
  },
  "http": {
    "cors": {
      "enabled": false,
      "allowedOrigins": []
    }
  },
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
      "models": ["gpt-5", "gpt-5-mini"],
      "capabilities": { "chat": true, "responses": true, "messages": true, "tools": true, "vision": false, "streaming": true }
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
      "models": ["qwen3:8b"],
      "capabilities": { "chat": true, "responses": true, "messages": true, "tools": true, "vision": false, "streaming": true }
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
| `capabilities` | `chat`, `responses`, `messages`, `tools`, `vision`, and `streaming` booleans used by capability-aware routing. |
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

### Anthropic Messages / Claude Code

OmniRoute-PS now exposes a native inbound Anthropic Messages endpoint:

```powershell
Invoke-RestMethod `
  -Uri 'http://127.0.0.1:20128/v1/messages' `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"model":"claude-test","max_tokens":256,"messages":[{"role":"user","content":[{"type":"text","text":"Hello"}]}]}'
```

Streaming uses Anthropic event names:

```text
event: message_start
event: content_block_delta
event: message_delta
event: message_stop
```

For Claude Code, point its Anthropic base URL at `http://127.0.0.1:20128` if the
client version allows a custom Messages API base URL. OmniRoute-PS translates the
Messages request into the Canonical IR and then to the selected upstream provider.

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
client-side authentication in v0.2.0, but some clients require an environment-key field
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
- **Claude Code:** point its Anthropic Messages base URL at
  `http://127.0.0.1:20128` when the client version supports a custom Messages API base URL.
  OmniRoute-PS exposes native `/v1/messages` and Anthropic-style SSE.

  ```powershell
  $env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:20128'
  $env:ANTHROPIC_API_KEY = 'local-placeholder'
  ```

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

## RunspacePool server

v0.2.0 replaces ThreadJob-per-request with a reusable native
`System.Management.Automation.Runspaces.RunspacePool`.

```text
HTTP listener accepts request
  -> bounded capacity check
  -> PowerShell pipeline uses a pooled runspace
  -> Invoke-OmniRouteHttpContext runs
  -> worker returns to pool
```

- Workers import `src/OmniRoute.psm1` once at pool startup.
- No request re-dot-sources source files.
- `minWorkers`, `maxWorkers`, and `maxQueuedRequests` are bounded by config.
- Saturation returns structured HTTP `503` with `Retry-After: 1`.
- Client write failures cancel the associated upstream stream.
- Shutdown stops acceptance, waits a bounded grace period, cancels remaining work,
  and disposes the listener and runspace pool.

## Canonical protocol IR

OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages are normalized
into one internal request/response shape before routing.

```text
Inbound protocol
  -> Canonical IR
  -> Router
  -> Provider adapter
  -> Canonical response/event
  -> Inbound protocol
```

The IR includes:

```text
model
messages[]
  role
  content[] text/image/tool_call/tool_result
tools[]
toolChoice
stream
generation temperature/topP/maxTokens/stop
metadata
```

Streaming events are normalized to `message_start`, `content_delta`,
`tool_call_start`, `tool_call_delta`, `message_end`, `error`, and `done`.

## Protocol compatibility matrix

| Client / API | Chat | Responses | Messages | SSE | Tools |
| --- | --- | --- | --- | --- | --- |
| Codex custom OpenAI provider | ✅ | ✅ limited | — | ✅ | ✅ OpenAI ↔ provider core paths |
| Claude Code Anthropic base URL | — | — | ✅ | ✅ | ✅ Anthropic ↔ provider core paths |
| Cline OpenAI Compatible | ✅ | ✅ limited | — | ✅ | ✅ OpenAI ↔ provider core paths |
| Continue OpenAI provider | ✅ | ✅ limited | — | ✅ | ✅ OpenAI ↔ provider core paths |
| OpenCode OpenAI provider | ✅ | ✅ limited | — | ✅ | ✅ OpenAI ↔ provider core paths |

“Limited” means documented and tested core fields, not every advanced Responses
or tool edge case. Unsupported fields return `unsupported_feature` or
`unsupported_parameter` instead of being silently dropped.

## Routing, fallback, and runtime state

Routing flow:

```text
model
  -> alias resolution
  -> explicit provider prefix
  -> most-specific route
  -> enabled + capable + model-compatible candidates
  -> score
  -> attempt
  -> success / fallback
```

Capability filtering happens before scoring. A request that needs tools, vision,
streaming, Responses, or Messages will not be sent to a provider that declares the
corresponding capability as `false`.

Provider runtime state includes availability, latency, moving average, rate-limit
temporary penalty, circuit state, recent error class, last success/failure, and
model incompatibility tracking.

Circuit breaking is driven only by provider availability errors:

- timeout;
- DNS/socket/connection failure;
- HTTP `502`, `503`, `504`;
- malformed upstream response.

HTTP `429` records a temporary routing penalty but does not mark the provider down.
HTTP `400` is ignored for circuit purposes. HTTP `401`/`403` is recorded as an auth
problem. `model_not_found` marks only that model/provider pair temporarily incompatible.

Fallback is attempted for timeouts, connection failures, malformed responses,
HTTP `429`, HTTP `500`, and the configured `5xx` list. It is not attempted for
ordinary invalid requests or unsupported protocol features.

## SSE implementation

When `stream: true` is requested:

1. OmniRoute-PS opens the upstream response with `HttpCompletionOption.ResponseHeadersRead`.
2. It reads incrementally with `StreamReader`.
3. It parses `event:` and `data:` fields into complete events.
4. It converts provider events into Canonical streaming events.
5. It renders OpenAI `data:` chunks, Responses events, or Anthropic SSE events.
6. It flushes every event immediately.
7. It cancels/disposes upstream work if the client stops reading.

Streaming fallback is not possible after upstream response headers have been sent; an
error event is emitted instead.

## Health, readiness, metrics, and reload

Health endpoints:

| Endpoint | Meaning |
| --- | --- |
| `GET /health/live` | Process liveness only; does not depend on providers. |
| `GET /health/ready` | Worker pool is initialized and at least one provider is usable. |
| `GET /health` | Full provider runtime state, config revision, and worker snapshot. |
| `GET /metrics` | Prometheus text exposition without a Prometheus SDK. |

Metrics include requests, active requests, queued requests, durations, provider
requests/failures, fallback count, circuit-open count, and active streams. Labels
are bounded to provider IDs and contain no prompts, request bodies, tokens,
cookies, or authorization values.

Config reload uses file-change polling with debounce. A candidate file is parsed
and validated before an atomic `ConfigState.Current` swap. Invalid reloads retain the
previous config and do not interrupt existing streams. Changes to `listen`/`port`
require a restart; all future requests use the new config object.

## CORS

CORS is disabled by default. When enabled, only explicit origins are allowed:

```json
"http": {
  "cors": {
    "enabled": true,
    "allowedOrigins": ["http://localhost:3000"]
  }
}
```

Wildcard origins and credentials are not supported.

## Security

- Default bind address is `127.0.0.1`.
- Binding to `0.0.0.0` prints an explicit network-exposure warning.
- Client authentication is not implemented in v0.2.0. Do not expose the router to an
  untrusted network.
- API keys are read from environment variables named by `apiKeyEnv`.
- Literal `apiKey` properties and sensitive custom headers are rejected by configuration
  validation.
- API keys, authorization headers, cookies, tokens, secrets, passwords, and prompt bodies
  are never written to normal logs or metrics.
- Upstream URLs are restricted to absolute `http` or `https` URLs without credentials,
  query strings, or fragments.
- CORS is disabled by default and uses an explicit allowlist when enabled.
- Malformed headers, CR/LF injection, and oversized request bodies are rejected.
- Client errors and upstream errors are returned as structured JSON without PowerShell
  stack traces. `-Debug` adds diagnostic detail only to the local console.

## Testing

Run the full suite:

```powershell
Import-Module Pester
Invoke-Pester -Path .\tests -Output Detailed
```

Current coverage includes:

- configuration parsing, schema, CORS, server limits, and provider capabilities;
- Canonical IR normalization for OpenAI, Responses, and Anthropic;
- OpenAI/Anthropic/Gemini tool mappings and tool-result round trips;
- routing, aliases, exact/wildcard routes, priority, capability filtering, unhealthy
  providers, fallback order, rate-limit penalties, auth errors, model incompatibility,
  and circuit transitions;
- RunspacePool-backed HTTP server startup, bounded queue overload `503`, worker reuse, and bounded shutdown;
- `/v1/chat/completions`, limited `/v1/responses`, and native `/v1/messages`;
- OpenAI and Anthropic SSE with delayed chunks and no full buffering;
- client write failure cancellation and stream cleanup;
- liveness/readiness/full health and Prometheus text output;
- valid and invalid config hot reload;
- no ThreadJob-per-request or per-request full dot-source audit.

Static analysis:

```powershell
Import-Module PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\omniroute.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

## Benchmarks

Measured on 2026-10-03 with PowerShell `7.6.5` on Windows `10.0.26200`,
using the self-contained local mock provider in
[`scripts/benchmark.ps1`](scripts/benchmark.ps1).

| Metric | v0.1.0 baseline | v0.2.0 |
| --- | ---: | ---: |
| `version` cold start, 5-run average | 1037.7 ms | 872.7 ms |
| Routing-only, 10,000 iterations | 0.5939 ms | 0.6958 ms |
| 100 sequential local mock completions | 172.5 ms/request | 21.95 ms/request |
| 20 parallel local mock completions | 1056.5 ms total | 815.4 ms total |
| 50 parallel local mock completions | not measured | 552.0 ms total |
| SSE first-chunk router delay | not measured | 108.6 ms |
| Router idle working set | 106.3 MB | 109.7 MB |
| Router loaded working set | 106.3 MB | 109.7 MB |
| ThreadJob per request | 1 | 0 |
| Per-request full dot-source | yes | no |

These are single-machine observations, not performance guarantees. Startup and
routing-only numbers vary with system load; sequential HTTP throughput is the clear
v0.2 architectural improvement.

Run the benchmark yourself:

```powershell
pwsh ./scripts/benchmark.ps1
pwsh ./scripts/benchmark.ps1 -Json
```

## Architecture

```text
omniroute.ps1
  -> Version.ps1      one version source for CLI, health, and User-Agent
  -> Protocol.ps1     canonical request/response/stream IR and tool mapping
  -> Config.ps1       schema-validated config, capabilities, CORS, server limits
  -> Transport.ps1    shared HttpClient, retries, timeouts, cancellation, SSE
  -> Adapters.ps1     endpoint/header resolution per protocol family
  -> Metrics.ps1      bounded counters and Prometheus text output
  -> Health.ps1       refined runtime state, readiness, circuit breaker
  -> Router.ps1       capability-aware candidate selection, fallback, stream conversion
  -> Server.ps1       RunspacePool, bounded queue, hot reload, health/metrics endpoints
  -> Logging.ps1      redacted console and JSON logs
```

The router state is process-local and resets on restart. There is no database and no
cross-process coordination.

## Limitations

- The OpenAI Responses layer supports the documented core fields and core tool mapping,
  not every advanced field or hosted tool.
- Tool translation covers the four required core paths, but exotic provider-specific
  tool schemas may return `unsupported_feature`.
- Streaming fallback cannot happen after response headers are sent.
- Health, metrics, circuit state, and rate-limit state are process-local and reset on
  restart.
- Changing `listen` or `port` via hot reload requires a restart; future requests use
  the new provider/routes/alias values.
- No client authentication, accounts, quotas, dashboards, MCP, MITM, proxy mode, or
  multi-user management.
- The measured idle working set remains above the aspirational 80 MB target because of
  the PowerShell runtime and pooled runspaces.
- PowerShell 7.4+ is required; Windows PowerShell 5.1 is not supported.

## Roadmap

### Current

- Stable local OpenAI-compatible routing, native Messages API, bounded RunspacePool,
  cross-protocol tools, circuit breaking, health/readiness, metrics, and hot reload.
- Cross-platform CI and a small auditable PowerShell codebase.

### Next

- Broaden Responses API and tool edge-case coverage.
- More protocol/schema conformance tests against local mocks.
- Improve routing-only hot-loop allocations.

### Future

- Optional Windows service integration.
- More local observability without a telemetry SaaS dependency.

### Not planned

- Web dashboard, database, MCP host, MITM/TPROXY, browser automation, RAG, vector DB,
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
