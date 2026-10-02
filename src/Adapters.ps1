Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OmniRouteProviderHeaders {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Provider)
    $headers = @{ Accept = 'application/json' }
    foreach ($name in $Provider.headers.Keys) { $headers[$name] = [string]$Provider.headers[$name] }
    if ($Provider.type -eq 'anthropic' -and -not $headers.ContainsKey('anthropic-version')) { $headers['anthropic-version'] = '2023-06-01' }
    $apiKey = Get-OmniRouteApiKey -Provider $Provider
    if (-not [string]::IsNullOrEmpty($apiKey)) { $headers[[string]$Provider.apiKeyHeader] = [string]$Provider.apiKeyPrefix + $apiKey }
    return $headers
}

function Get-OmniRouteProviderEndpoint {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][bool]$Stream
    )
    switch ($Provider.type) {
        { $_ -in @('openai', 'custom-openai', 'ollama') } { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'chat/completions' }
        'anthropic' { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'messages' }
        'gemini' {
            $encodedModel = [Uri]::EscapeDataString($Model)
            if ($Stream) { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path "models/$encodedModel`:streamGenerateContent?alt=sse" }
            return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path "models/$encodedModel`:generateContent"
        }
        default { throw "Unsupported provider type '$($Provider.type)'." }
    }
}

function Get-OmniRouteProviderProbeUri {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Provider)
    if (-not [string]::IsNullOrWhiteSpace([string]$Provider.healthPath)) { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path ([string]$Provider.healthPath) }
    return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'models'
}
