# Changelog

All notable changes to OmniRoute-PS are documented in this file.
The format follows Keep a Changelog, and releases use Semantic Versioning.

## [0.2.0] - 2026-10-03

### Added

- Reusable native RunspacePool server with bounded workers and bounded request queue.
- Canonical Protocol IR for OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages.
- Native inbound `POST /v1/messages` with Anthropic-style SSE events.
- Cross-protocol tools for OpenAI, Anthropic, and Gemini core paths.
- Capability-aware routing for protocol, tools, vision, and streaming.
- Refined provider runtime state with availability, latency, rate-limit, auth, model compatibility,
  circuit, and error-class tracking.
- `GET /health/live`, `GET /health/ready`, and enhanced `GET /health`.
- Prometheus-compatible `GET /metrics`.
- JSON Schema and `config schema` / `config validate` CLI commands.
- Atomic config hot reload with debounce.
- Secure-by-default CORS configuration.
- Structured overload error `worker_pool_saturated` with `Retry-After: 1`.

### Changed

- Replaced ThreadJob-per-request with pooled runspaces that import `OmniRoute.psm1` once.
- Replaced pairwise provider request/response conversion with Canonical IR conversion.
- Updated version metadata to `0.2.0` through a single version source.
- Updated health semantics so readiness requires an available provider and an initialized worker pool.
- Refactored routing penalties so 429, auth failures, and model incompatibility do not falsely
  open provider circuits.

### Performance

- 100 sequential local mock completions improved from 172.5 ms/request to 21.95 ms/request.
- 50 parallel local mock completions measured at 552.0 ms total.
- ThreadJob-per-request count reduced to `0`.
- Per-request full source dot-source count reduced to `0`.

### Security

- CORS disabled by default and restricted to explicit origins when enabled.
- Metrics and logs exclude prompts, API keys, Authorization headers, cookies, and user content.
- Request queue overflow returns bounded structured errors instead of unbounded queuing.

### Compatibility

- Claude Code can use the inbound Anthropic Messages endpoint when its client version supports
  a custom Messages API base URL.
- Codex can use the limited Responses-compatible endpoint through a custom provider.
- OpenAI/Anthropic/Gemini tool calls and tool results are normalized for the core supported paths.

### Known limitations

- Advanced OpenAI Responses fields and provider-specific hosted tools remain limited.
- Streaming provider fallback cannot occur after response headers are sent.
- Runtime health, metrics, circuit state, and rate-limit state are process-local.
- Config changes to `listen` or `port` require restart.
- Idle memory remains above the aspirational 80 MB target on the measured Windows machine.

## [0.1.0] - 2026-10-02

### Added

- OpenAI-compatible `POST /v1/chat/completions` and limited `POST /v1/responses`.
- Streaming SSE forwarding with incremental upstream reads and cancellation.
- OpenAI, custom OpenAI, Ollama, Anthropic, and Gemini protocol adapters.
- Wildcard routing, aliases, explicit `provider:model` selection, scoring, and fallback.
- In-process circuit breaker with Closed, Open, and HalfOpen states.
- JSON configuration validation and environment-variable secret references.
- CLI commands: `serve`, `status`, `models`, `providers`, `test`, `check`, `version`, and `help`.
- Pester tests, PSScriptAnalyzer configuration, cross-platform GitHub Actions, install script, and benchmark script.

[0.1.0]: https://github.com/styayur/OmniRoute-PS/releases/tag/v0.1.0

[0.2.0]: https://github.com/styayur/OmniRoute-PS/releases/tag/v0.2.0
