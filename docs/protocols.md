# Protocol scope

[Back to README](../README.md). Examples run from the repository root after configuring a provider and starting the router. Requests can consume paid upstream quota.

| Inbound API | Implemented scope | Evidence |
| --- | --- | --- |
| `/v1/chat/completions` | Core messages, function tools, streaming | Protocol and local HTTP mock tests |
| `/v1/responses` | Core input/instructions, function tools, streaming; limited fields | Protocol and local HTTP mock tests |
| `/v1/messages` | Core Anthropic messages, tools and SSE | Protocol and local HTTP mock tests |

These tests validate protocol paths, not end-to-end compatibility with every version of Codex, Claude Code, Cline, Continue or OpenCode. Configure clients only if their current version accepts the corresponding base URL and supported fields. Model IDs in the example are illustrative, not a live provider catalog.

The OpenAI-compatible base URL is `http://127.0.0.1:20128/v1`; the Anthropic base URL is `http://127.0.0.1:20128`. If a client requires a key, use a local placeholder, never an upstream secret. The router does not authenticate clients.

Advanced Responses features, hosted tools and provider-specific schemas are not generally supported. Unsupported fields/features produce errors; a mid-stream failure cannot transparently fail over. See [Protocol.ps1](../src/Protocol.ps1) and [protocol tests](../tests/Protocol.Tests.ps1) for the maintained implementation.

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
`metadata`, `user`, `seed`, `tools`, and `tool_choice`. Unsupported advanced fields return a clear `unsupported_parameter`
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
