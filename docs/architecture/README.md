# Architecture evidence

Source review: `c3cdbf78d17515edd1b875be56d5affc9462417e` (2026-10-09).

The marked Mermaid block in [README](../../README.md) is the only maintained diagram source. GitHub renders it natively in the reader's theme. No duplicate SVG or independent `.mmd` is committed; extracted Mermaid and SVG files are disposable verification artifacts.

Model resolution and health scoring are functions within Router.ps1, not separate services. Server.ps1 converts inbound protocol messages to canonical IR; Router.ps1 selects usable candidates and combines Protocol.ps1 conversion with Adapters.ps1 endpoint/header resolution. Transport owns HTTP requests and streaming sessions. The return path is converted back to the client's protocol.

Health/circuit state is shared in-process and resets on restart; there is no database or distributed coordinator. Bounded queue overload returns 503. Invalid config reload retains the previous config. Fallback can select another provider before a stream begins, but a mid-stream failure cannot restart transparently. Provider credentials are resolved from environment variables; the default listener is local and CORS is disabled unless configured.

## Source map

- [src/Server.ps1](../../src/Server.ps1): `RunspacePool`, `ConvertTo-OmniRouteCanonicalRequest`, `503`
- [src/Router.ps1](../../src/Router.ps1): `Resolve-OmniRouteModel`, `Get-OmniRouteProviderScore`, `Get-OmniRouteCandidates`, `Start-OmniRouteStream`, `Invoke-OmniRouteStream`
- [src/Health.ps1](../../src/Health.ps1): `Get-OmniCircuitState`, `Set-OmniProviderFailure`
- [src/Protocol.ps1](../../src/Protocol.ps1): `ConvertFrom-OmniRouteCanonicalRequest`
- [src/Adapters.ps1](../../src/Adapters.ps1): `Get-OmniRouteProviderHeaders`
- [src/Transport.ps1](../../src/Transport.ps1): `Invoke-OmniRouteUpstreamRequest`
- [src/Config.ps1](../../src/Config.ps1): `Get-OmniRouteApiKey`

The anchors in `evidence.json` catch renamed/deleted source symbols; they do not prove call semantics. The source review above checked the actual call sites and boundaries. A significant change to data flow, persistence, authentication, recovery or process boundaries requires reviewing this diagram and updating the evidence. Routine edits do not require redrawing it.

## Verification

Requires Python 3, Node.js 22+ and network access for the documentation-only Mermaid CLI. From the repository root:

```sh
python docs/architecture/verify.py --render
```

This checks local README image references and source anchors, extracts the authoritative block, renders it twice with Mermaid CLI 11.12.0 using deterministic IDs, compares SVG bytes, validates SVG XML, and also renders the dark theme. If the bundled browser is unavailable, pass `--chrome /absolute/path/to/chrome` (or set `PUPPETEER_EXECUTABLE_PATH`). The CLI version is pinned; its transitive npm dependencies and the browser are environment-dependent, so the byte comparison proves repeatability within the same installed toolchain. Output goes to a temporary directory, never application runtime dependencies. GitHub Markdown/browser rendering still requires visual review; CLI validation alone is not evidence of GitHub rendering.

GitDiagram returned an initial diagram on 2026-10-09 for the public repository as a discovery aid. Its page reported **0 source files read**, so its README-derived connections were checked directly against the local PowerShell source. Its generated output is not imported as authoritative architecture or licensed artwork. No private source, config or credentials were submitted.

Existing repository licenses and third-party notices continue to apply. These diagrams are documentation authored from this repository's public source; no app icons, installer assets or third-party marks are replaced.
