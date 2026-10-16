# Contributing

Keep changes small, PowerShell-native and CLI-first. Preserve read-only inspection commands and document the scope of any mutation and recovery. Runtime dependencies should remain minimal.

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

Run `python docs/architecture/verify.py` for source anchors and documentation references. Architecture CI also renders Mermaid; CodeForge regression and both Windows/Ubuntu PowerShell jobs remain required review evidence. Tests use local mock upstreams; they do not certify paid provider or desktop-client compatibility. Submit reproducible bugs and scoped changes through GitHub issues and pull requests.
