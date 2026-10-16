# Security

Keep the listener on `127.0.0.1`: client authentication is not implemented. CORS is disabled by default and is not an authentication mechanism. Do not expose this router to untrusted users or networks. Requests and configured credentials are sent to your selected upstreams.

Use environment-variable references (`apiKeyEnv`), not literal secrets in JSON. Logging has redaction and body-exclusion paths, but review diagnostics before sharing them. Never include keys, prompts or private provider URLs in public reports.

The optional installer has known launcher/recovery defects described in [installation](docs/installation.md). Prefer running a reviewed checkout until those paths are repaired and tested.

Report suspected vulnerabilities using [GitHub private reporting](https://github.com/styayur/OmniRoute-PS/security/advisories/new) when available. Do not post exploit details or credentials to a public issue. There is no guaranteed response time or security certification.
