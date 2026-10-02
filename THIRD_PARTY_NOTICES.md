# Third-Party Notices

OmniRoute-PS is an independent clean-room implementation licensed under the
Apache License 2.0. No source code from OmniRoute or other third-party projects
has been copied into this repository.

## Inspiration

### OmniRoute

- Project: https://github.com/diegosouzapw/OmniRoute
- License: MIT
- Use: conceptual inspiration for unified LLM API routing only.
- Note: OmniRoute-PS is not a fork, translation, or drop-in replacement for
  the full OmniRoute platform. Its PowerShell and .NET implementation is
  original project code.

## Runtime platform components

OmniRoute-PS has no bundled npm, Python, database, browser, Electron, or
third-party PowerShell runtime dependency.

It uses .NET types supplied by the user's PowerShell 7.4+ installation,
including `System.Net.Http`, `System.Net.HttpListener`, and
`System.Text.Json`-compatible JSON conversion provided by PowerShell.

- .NET: https://github.com/dotnet/runtime
- License: MIT
- Use: HTTP transport, cancellation, streaming, and local HTTP listener.

## Development-only tools

The CI workflow installs these test and lint tools; they are not shipped as
runtime dependencies of OmniRoute-PS.

| Tool | Project | License | Use |
| --- | --- | --- | --- |
| Pester | https://github.com/pester/Pester | Apache-2.0 | PowerShell tests |
| PSScriptAnalyzer | https://github.com/PowerShell/PSScriptAnalyzer | MIT | Static analysis |

## Provider services

Provider names and APIs referenced in configuration examples are trademarks
and services of their respective owners. OmniRoute-PS does not bundle provider
SDKs, models, data, or credentials. Users are responsible for complying with
each provider's terms and API usage policies.
