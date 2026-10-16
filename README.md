# OmniRoute-PS

A lightweight, local-first AI request router for PowerShell 7: one local endpoint, model routing and failover across configured providers.

**Beta · PowerShell-native · CLI-first · Read-only-first · Reversible operations · Minimal dependencies**

[![CI](https://github.com/styayur/OmniRoute-PS/actions/workflows/ci.yml/badge.svg)](https://github.com/styayur/OmniRoute-PS/actions/workflows/ci.yml)
[Releases](https://github.com/styayur/OmniRoute-PS/releases) · [Configuration](docs/configuration.md) · [Protocol scope](docs/protocols.md)

For developers whose scripts or clients accept a custom OpenAI-compatible or Anthropic endpoint. Route by model alias, wildcard or explicit provider; select capable providers and fall back on eligible upstream failures. No database, provider SDK or third-party PowerShell runtime module is required.

## Quick start

Install PowerShell **7.4+**, then clone and inspect the scripts:

```powershell
git clone https://github.com/styayur/OmniRoute-PS.git
cd OmniRoute-PS
pwsh ./omniroute.ps1 check -ConfigPath ./omniroute.example.json
```

Actual configuration-check excerpt (2026-10-16; path and missing-key warnings omitted):

```text
valid     : True
errors    : {}
providers : 6
routes    : 6
aliases   : 3
```

This is an offline configuration check, not an authenticated inference test. Example model IDs must be checked against your provider. Copy the example once, edit providers/routes, and supply only the keys needed by your configuration:

```powershell
Copy-Item ./omniroute.example.json ./omniroute.json
# Edit omniroute.json; use apiKeyEnv references, never literal API keys.
$env:OPENAI_API_KEY = '<your-key>'
pwsh ./omniroute.ps1 check -ConfigPath ./omniroute.json
pwsh ./omniroute.ps1 serve -ConfigPath ./omniroute.json
```

**Keep the default loopback binding. There is no client authentication.** Starting the router opens a local HTTP listener; client requests may consume upstream quota. Stop with Ctrl+C. Back up configuration before edits; hot reload is not a disk backup.

## Everyday use

From another terminal in the repository directory:

```powershell
pwsh ./omniroute.ps1 status -ConfigPath ./omniroute.json -Json
pwsh ./omniroute.ps1 models -ConfigPath ./omniroute.json -Json
pwsh ./omniroute.ps1 providers -ConfigPath ./omniroute.json -Json
pwsh ./omniroute.ps1 test -ConfigPath ./omniroute.json
pwsh ./omniroute.ps1 help
```

`models` lists configured IDs, not a live provider catalog. `status`/`providers` query the local router. `test` is offline unless you explicitly add `-Live` to probe upstreams. Use `http://127.0.0.1:20128/v1` for supported OpenAI requests; see [protocol examples](docs/protocols.md) before connecting a client.

## Requirements and limits

- PowerShell 7.4+; Windows is the primary target and core tests also run on Ubuntu. Windows PowerShell 5.1 is unsupported.
- OpenAI Chat, limited Responses and Anthropic Messages paths are tested with local mocks. This does not certify every desktop client or live provider.
- Streaming cannot fail over after response headers are sent. Health, metrics and circuit state are process-local and reset on restart.
- Listen address/port changes require restart. No client authentication or multi-user isolation is provided.
- Prefer a checkout/archive: the published v0.2.0 optional installer has launcher/recovery defects, repaired in current source; see [installation details](docs/installation.md#optional-installer-current-limitations).

## Documentation

| Need | Guide |
| --- | --- |
| Download, verify, recover or remove | [Installation and recovery](docs/installation.md) |
| Configure routes, providers, health and reload | [Configuration](docs/configuration.md) · [JSON schema](schemas/omniroute.schema.json) |
| Send requests and understand compatibility | [Protocol scope and examples](docs/protocols.md) |
| Understand internals and measured benchmarks | [Architecture and source evidence](docs/architecture/README.md) |
| Review version changes | [Changelog](CHANGELOG.md) |

中文：这是本地优先的 PowerShell AI 请求路由工具。先运行 `check` 检查配置，再启动服务；不要将无客户端认证的监听端口暴露到不可信网络。协议测试不代表所有客户端和模型均兼容。

## License and contributing

[Apache-2.0](LICENSE) · [Contributing and tests](CONTRIBUTING.md) · [Security](SECURITY.md) · [Issues](https://github.com/styayur/OmniRoute-PS/issues)

Independent implementation inspired by [OmniRoute](https://github.com/diegosouzapw/OmniRoute). See [NOTICE](NOTICE) and [third-party attribution](THIRD_PARTY_NOTICES.md).
