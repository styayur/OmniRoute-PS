# Configuration and operation

[Back to README](../README.md). Run commands from the repository root.

## Configuration
The default lookup order is:

1. `$env:OMNIROUTE_CONFIG`
2. `./omniroute.json`
3. `./omniroute.example.json`

`OMNIROUTE_HOST` and `OMNIROUTE_PORT` override `listen` and `port`.

The JSON Schema is [schemas/omniroute.schema.json](../schemas/omniroute.schema.json).
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
