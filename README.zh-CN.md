# OmniRoute-PS

本地优先的 PowerShell 7 AI 请求路由工具：用一个本地端点，将请求按模型分发给配置的提供商，并在符合条件的失败后切换提供商。

[English](README.md) · [发布记录](https://github.com/styayur/OmniRoute-PS/releases) · [配置说明](docs/configuration.md) · [协议范围](docs/protocols.md)

**Beta。** 适合支持自定义 OpenAI 兼容端点或 Anthropic 端点的脚本和客户端。支持模型别名、通配符及指定提供商；不需要数据库、提供商 SDK 或第三方 PowerShell 运行时模块。

## 快速开始

安装 **PowerShell 7.4+**，克隆并检查脚本：

```powershell
git clone https://github.com/styayur/OmniRoute-PS.git
cd OmniRoute-PS
pwsh ./omniroute.ps1 check -ConfigPath ./omniroute.example.json
```

英文版记录了 16-10-2026 的实际离线配置检查输出。检查通过不等于已验证密钥或实际推理；示例模型 ID 需要按提供商核对。首次复制配置后，编辑提供商和路由，并仅设置所需密钥：

```powershell
Copy-Item ./omniroute.example.json ./omniroute.json
# 编辑 omniroute.json；使用 apiKeyEnv 引用，不要写入密钥字面值。
$env:OPENAI_API_KEY = '<your-key>'
pwsh ./omniroute.ps1 check -ConfigPath ./omniroute.json
pwsh ./omniroute.ps1 serve -ConfigPath ./omniroute.json
```

**保留默认 loopback 监听；服务没有客户端认证。** 请求可能消耗提供商额度。用 Ctrl+C 停止。修改前备份配置；热重载不是磁盘备份。

## 日常使用

在仓库目录的另一个终端运行：

```powershell
pwsh ./omniroute.ps1 status -ConfigPath ./omniroute.json -Json
pwsh ./omniroute.ps1 models -ConfigPath ./omniroute.json -Json
pwsh ./omniroute.ps1 providers -ConfigPath ./omniroute.json -Json
pwsh ./omniroute.ps1 test -ConfigPath ./omniroute.json
pwsh ./omniroute.ps1 help
```

`models` 列出配置的模型，不是提供商的实时目录。`status` / `providers` 查询本地路由服务。`test` 默认离线，只有显式加入 `-Live` 才探测上游。支持的 OpenAI 请求使用 `http://127.0.0.1:20128/v1`；连接客户端前阅读[协议示例](docs/protocols.md)。

## 平台、测试与限制

- Windows 是主要平台，核心测试也在 Ubuntu 运行；不支持 Windows PowerShell 5.1。
- OpenAI Chat、有限的 Responses 和 Anthropic Messages 使用本地模拟上游测试；不能据此保证所有桌面客户端或真实提供商兼容。
- 流式响应发送头部后不能故障转移。健康状态、指标和熔断状态保存在当前进程，重启后重置。
- 修改监听地址或端口需要重启；没有客户端认证或多用户隔离。
- 优先使用源码检出或归档。已发布 v0.2.0 的可选安装器有启动器及恢复缺陷，当前源码已修复；见[安装限制](docs/installation.md#optional-installer-current-limitations)。

## 文档与贡献

[安装、恢复与移除](docs/installation.md) · [配置](docs/configuration.md) · [JSON Schema](schemas/omniroute.schema.json) · [架构和测量依据](docs/architecture/README.md) · [变更记录](CHANGELOG.md)

[贡献及测试](CONTRIBUTING.md)包含 Pester、PSScriptAnalyzer 和架构验证命令。现有 CI 保留 Windows、Ubuntu、架构及 CodeForge 检查。通过 [Issues](https://github.com/styayur/OmniRoute-PS/issues) 提交可复现问题；漏洞按 [SECURITY.md](SECURITY.md) 处理。

## 许可证

[Apache-2.0](LICENSE)。这是受 [OmniRoute](https://github.com/diegosouzapw/OmniRoute) 启发的独立实现，来源说明见 [NOTICE](NOTICE) 和[第三方声明](THIRD_PARTY_NOTICES.md)。
