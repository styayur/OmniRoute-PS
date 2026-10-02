# Changelog

All notable changes to OmniRoute-PS are documented in this file.
The format follows Keep a Changelog, and releases use Semantic Versioning.

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
