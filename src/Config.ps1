Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OmniRouteDictValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Dictionary,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    if ($Dictionary -is [System.Collections.IDictionary] -and $Dictionary.Contains($Name)) {
        return $Dictionary[$Name]
    }
    return $Default
}

function ConvertTo-OmniRouteStringArray {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @([string]$Value) }
    return @($Value | ForEach-Object { [string]$_ })
}

function New-OmniRouteIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{
        path    = $Path
        message = $Message
    }
}

function Resolve-OmniRouteConfigPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path,
        [string]$BasePath = (Get-Location).Path
    )

    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:OMNIROUTE_CONFIG }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $local = Join-Path $BasePath 'omniroute.json'
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            $candidate = $local
        }
        else {
            $candidate = Join-Path $BasePath 'omniroute.example.json'
        }
    }

    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $BasePath $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Read-OmniRouteConfigFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $parsed = $raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Configuration JSON is invalid: $($_.Exception.Message)"
    }
    if ($parsed -isnot [System.Collections.IDictionary]) {
        throw 'Configuration root must be a JSON object.'
    }
    return $parsed
}

function Test-OmniRouteBaseUrl {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -notin @('http', 'https')) { return $false }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) { return $false }
    return $true
}

function ConvertTo-OmniRouteConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$RawConfig,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $errors = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()

    $listen = [string](Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'listen' -Default '127.0.0.1')
    if (-not [string]::IsNullOrWhiteSpace($env:OMNIROUTE_HOST)) { $listen = $env:OMNIROUTE_HOST }
    if ($listen -ne 'localhost' -and $listen -ne '*') {
        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($listen, [ref]$address)) {
            $errors.Add((New-OmniRouteIssue -Path 'listen' -Message 'Must be localhost, *, or a valid IP address.'))
        }
    }

    $portValue = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'port' -Default 20128
    if (-not [string]::IsNullOrWhiteSpace($env:OMNIROUTE_PORT)) { $portValue = $env:OMNIROUTE_PORT }
    $port = 0
    if (-not [int]::TryParse([string]$portValue, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        $errors.Add((New-OmniRouteIssue -Path 'port' -Message 'Must be an integer from 1 to 65535.'))
        $port = 20128
    }

    $requestTimeoutSeconds = [int](Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'requestTimeoutSeconds' -Default 120)
    if ($requestTimeoutSeconds -lt 1 -or $requestTimeoutSeconds -gt 3600) {
        $errors.Add((New-OmniRouteIssue -Path 'requestTimeoutSeconds' -Message 'Must be from 1 to 3600 seconds.'))
        $requestTimeoutSeconds = 120
    }

    $maxRequestBodyBytes = [int](Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'maxRequestBodyBytes' -Default 1048576)
    if ($maxRequestBodyBytes -lt 1024 -or $maxRequestBodyBytes -gt 16777216) {
        $errors.Add((New-OmniRouteIssue -Path 'maxRequestBodyBytes' -Message 'Must be from 1024 to 16777216 bytes.'))
        $maxRequestBodyBytes = 1048576
    }

    $healthCacheSeconds = [int](Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'healthCacheSeconds' -Default 15)
    if ($healthCacheSeconds -lt 1 -or $healthCacheSeconds -gt 300) {
        $errors.Add((New-OmniRouteIssue -Path 'healthCacheSeconds' -Message 'Must be from 1 to 300 seconds.'))
        $healthCacheSeconds = 15
    }

    $serverRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'server' -Default @{}
    if ($serverRaw -isnot [System.Collections.IDictionary]) { $errors.Add((New-OmniRouteIssue -Path 'server' -Message 'Must be an object.')); $serverRaw = @{} }
    $server = @{
        minWorkers          = [int](Get-OmniRouteDictValue -Dictionary $serverRaw -Name 'minWorkers' -Default 2)
        maxWorkers          = [int](Get-OmniRouteDictValue -Dictionary $serverRaw -Name 'maxWorkers' -Default ([Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount))))
        maxQueuedRequests   = [int](Get-OmniRouteDictValue -Dictionary $serverRaw -Name 'maxQueuedRequests' -Default 64)
        shutdownGraceSeconds = [int](Get-OmniRouteDictValue -Dictionary $serverRaw -Name 'shutdownGraceSeconds' -Default 5)
    }
    if ($server.minWorkers -lt 1 -or $server.minWorkers -gt 128) {
        $errors.Add((New-OmniRouteIssue -Path 'server.minWorkers' -Message 'Must be from 1 to 128.'))
        $server.minWorkers = 2
    }
    if ($server.maxWorkers -lt 1 -or $server.maxWorkers -gt 128) {
        $errors.Add((New-OmniRouteIssue -Path 'server.maxWorkers' -Message 'Must be from 1 to 128.'))
        $server.maxWorkers = 8
    }
    if ($server.minWorkers -gt $server.maxWorkers) {
        $errors.Add((New-OmniRouteIssue -Path 'server.minWorkers' -Message 'Must be less than or equal to server.maxWorkers.'))
        $server.minWorkers = $server.maxWorkers
    }
    if ($server.maxQueuedRequests -lt 0 -or $server.maxQueuedRequests -gt 10000) {
        $errors.Add((New-OmniRouteIssue -Path 'server.maxQueuedRequests' -Message 'Must be from 0 to 10000.'))
        $server.maxQueuedRequests = 64
    }
    if ($server.shutdownGraceSeconds -lt 0 -or $server.shutdownGraceSeconds -gt 300) {
        $errors.Add((New-OmniRouteIssue -Path 'server.shutdownGraceSeconds' -Message 'Must be from 0 to 300 seconds.'))
        $server.shutdownGraceSeconds = 5
    }

    $httpRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'http' -Default @{}
    if ($httpRaw -isnot [System.Collections.IDictionary]) { $errors.Add((New-OmniRouteIssue -Path 'http' -Message 'Must be an object.')); $httpRaw = @{} }
    $corsRaw = Get-OmniRouteDictValue -Dictionary $httpRaw -Name 'cors' -Default @{}
    if ($corsRaw -isnot [System.Collections.IDictionary]) { $errors.Add((New-OmniRouteIssue -Path 'http.cors' -Message 'Must be an object.')); $corsRaw = @{} }
    $http = @{
        cors = @{
            enabled        = [bool](Get-OmniRouteDictValue -Dictionary $corsRaw -Name 'enabled' -Default $false)
            allowedOrigins = @(ConvertTo-OmniRouteStringArray -Value (Get-OmniRouteDictValue -Dictionary $corsRaw -Name 'allowedOrigins' -Default @()))
        }
    }
    foreach ($origin in @($http.cors.allowedOrigins)) {
        $originUri = $null
        if (-not [Uri]::TryCreate([string]$origin, [UriKind]::Absolute, [ref]$originUri) -or $originUri.Scheme -notin @('http', 'https') -or -not [string]::IsNullOrEmpty($originUri.AbsolutePath.TrimEnd('/')) -or $originUri.AbsolutePath -ne '/') {
            $errors.Add((New-OmniRouteIssue -Path 'http.cors.allowedOrigins' -Message "Invalid origin '$origin'. Use scheme://host[:port] without a path."))
        }
    }

    $retryRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'retry' -Default @{}
    $retry = @{
        maxAttempts = [int](Get-OmniRouteDictValue -Dictionary $retryRaw -Name 'maxAttempts' -Default 2)
        baseDelayMs = [int](Get-OmniRouteDictValue -Dictionary $retryRaw -Name 'baseDelayMs' -Default 100)
    }
    if ($retry.maxAttempts -lt 1 -or $retry.maxAttempts -gt 5) {
        $errors.Add((New-OmniRouteIssue -Path 'retry.maxAttempts' -Message 'Must be from 1 to 5.'))
        $retry.maxAttempts = 2
    }
    if ($retry.baseDelayMs -lt 0 -or $retry.baseDelayMs -gt 10000) {
        $errors.Add((New-OmniRouteIssue -Path 'retry.baseDelayMs' -Message 'Must be from 0 to 10000 milliseconds.'))
        $retry.baseDelayMs = 100
    }

    $breakerRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'circuitBreaker' -Default @{}
    $breaker = @{
        failureThreshold = [int](Get-OmniRouteDictValue -Dictionary $breakerRaw -Name 'failureThreshold' -Default 3)
        openSeconds = [int](Get-OmniRouteDictValue -Dictionary $breakerRaw -Name 'openSeconds' -Default 30)
        halfOpenMaxAttempts = [int](Get-OmniRouteDictValue -Dictionary $breakerRaw -Name 'halfOpenMaxAttempts' -Default 1)
    }
    if ($breaker.failureThreshold -lt 1 -or $breaker.failureThreshold -gt 100) {
        $errors.Add((New-OmniRouteIssue -Path 'circuitBreaker.failureThreshold' -Message 'Must be from 1 to 100.'))
        $breaker.failureThreshold = 3
    }
    if ($breaker.openSeconds -lt 1 -or $breaker.openSeconds -gt 3600) {
        $errors.Add((New-OmniRouteIssue -Path 'circuitBreaker.openSeconds' -Message 'Must be from 1 to 3600 seconds.'))
        $breaker.openSeconds = 30
    }
    if ($breaker.halfOpenMaxAttempts -lt 1 -or $breaker.halfOpenMaxAttempts -gt 10) {
        $errors.Add((New-OmniRouteIssue -Path 'circuitBreaker.halfOpenMaxAttempts' -Message 'Must be from 1 to 10.'))
        $breaker.halfOpenMaxAttempts = 1
    }

    $fallbackOnStatus = @(Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'fallbackOnStatus' -Default @(429, 500, 502, 503, 504))
    foreach ($status in $fallbackOnStatus) {
        $parsedStatus = 0
        if (-not [int]::TryParse([string]$status, [ref]$parsedStatus) -or $parsedStatus -lt 400 -or $parsedStatus -gt 599) {
            $errors.Add((New-OmniRouteIssue -Path 'fallbackOnStatus' -Message "Invalid status code '$status'."))
        }
    }

    $loggingRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'logging' -Default @{}
    $logging = @{
        level  = [string](Get-OmniRouteDictValue -Dictionary $loggingRaw -Name 'level' -Default 'information')
        format = [string](Get-OmniRouteDictValue -Dictionary $loggingRaw -Name 'format' -Default 'console')
    }
    if ($logging.level.ToLowerInvariant() -notin @('debug', 'information', 'warning', 'error')) {
        $errors.Add((New-OmniRouteIssue -Path 'logging.level' -Message 'Must be debug, information, warning, or error.'))
    }
    if ($logging.format.ToLowerInvariant() -notin @('console', 'json')) {
        $errors.Add((New-OmniRouteIssue -Path 'logging.format' -Message 'Must be console or json.'))
    }

    $providersRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'providers' -Default @{}
    if ($providersRaw -isnot [System.Collections.IDictionary] -or $providersRaw.Count -eq 0) {
        $errors.Add((New-OmniRouteIssue -Path 'providers' -Message 'Must be a non-empty object.'))
        $providersRaw = @{}
    }

    $allowedTypes = @('openai', 'anthropic', 'gemini', 'ollama', 'custom-openai')
    $providers = @{}
    foreach ($providerId in @($providersRaw.Keys)) {
        $providerRaw = $providersRaw[$providerId]
        $providerPath = "providers.$providerId"
        $id = [string]$providerId
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            $errors.Add((New-OmniRouteIssue -Path $providerPath -Message 'Provider ID must use letters, digits, dot, underscore, or hyphen.'))
            continue
        }
        if ($providerRaw -isnot [System.Collections.IDictionary]) {
            $errors.Add((New-OmniRouteIssue -Path $providerPath -Message 'Provider definition must be an object.'))
            continue
        }
        if ($providerRaw.Contains('apiKey') -or $providerRaw.Contains('apikey')) {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.apiKey" -Message 'Literal API keys are prohibited. Use apiKeyEnv.'))
        }

        $type = ([string](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'type' -Default 'openai')).ToLowerInvariant()
        if ($type -notin $allowedTypes) {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.type" -Message "Unsupported provider type '$type'."))
        }

        $baseUrl = ([string](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'baseUrl' -Default '')).TrimEnd('/')
        if (-not (Test-OmniRouteBaseUrl -BaseUrl $baseUrl)) {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.baseUrl" -Message 'Must be an absolute http or https URL without credentials, query, or fragment.'))
        }

        $apiKeyEnv = [string](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'apiKeyEnv' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($apiKeyEnv) -and $apiKeyEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.apiKeyEnv" -Message 'Must be a valid environment variable name.'))
        }
        if ($type -ne 'ollama' -and [string]::IsNullOrWhiteSpace($apiKeyEnv)) {
            $warnings.Add((New-OmniRouteIssue -Path "$providerPath.apiKeyEnv" -Message 'No apiKeyEnv configured; unauthenticated requests will be attempted.'))
        }
        if (-not [string]::IsNullOrWhiteSpace($apiKeyEnv) -and [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($apiKeyEnv))) {
            $warnings.Add((New-OmniRouteIssue -Path "$providerPath.apiKeyEnv" -Message "Environment variable '$apiKeyEnv' is not set."))
        }

        $capabilitiesRaw = Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'capabilities' -Default @{}
        if ($capabilitiesRaw -isnot [System.Collections.IDictionary]) { $errors.Add((New-OmniRouteIssue -Path "$providerPath.capabilities" -Message 'Must be an object.')); $capabilitiesRaw = @{} }
        $capabilities = @{
            chat      = [bool](Get-OmniRouteDictValue -Dictionary $capabilitiesRaw -Name 'chat' -Default $true)
            responses = [bool](Get-OmniRouteDictValue -Dictionary $capabilitiesRaw -Name 'responses' -Default $true)
            messages  = [bool](Get-OmniRouteDictValue -Dictionary $capabilitiesRaw -Name 'messages' -Default $true)
            tools     = [bool](Get-OmniRouteDictValue -Dictionary $capabilitiesRaw -Name 'tools' -Default $true)
            vision    = [bool](Get-OmniRouteDictValue -Dictionary $capabilitiesRaw -Name 'vision' -Default $false)
            streaming = [bool](Get-OmniRouteDictValue -Dictionary $capabilitiesRaw -Name 'streaming' -Default $true)
        }

        $defaultHeader = if ($type -eq 'anthropic') { 'x-api-key' } elseif ($type -eq 'gemini') { 'x-goog-api-key' } else { 'Authorization' }
        $apiKeyHeader = [string](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'apiKeyHeader' -Default $defaultHeader)
        if ($apiKeyHeader -notmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$') {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.apiKeyHeader" -Message 'Invalid HTTP header name.'))
        }
        $apiKeyPrefix = [string](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'apiKeyPrefix' -Default $(if ($apiKeyHeader -ieq 'Authorization') { 'Bearer ' } else { '' }))
        if ($apiKeyPrefix -match '[\r\n]') {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.apiKeyPrefix" -Message 'Header values cannot contain CR or LF.'))
        }

        $headers = @{}
        $headersRaw = Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'headers' -Default @{}
        if ($headersRaw -is [System.Collections.IDictionary]) {
            foreach ($headerName in @($headersRaw.Keys)) {
                $headerValue = [string]$headersRaw[$headerName]
                if ($headerName -notmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$') {
                    $errors.Add((New-OmniRouteIssue -Path "$providerPath.headers.$headerName" -Message 'Invalid HTTP header name.'))
                }
                if ($headerName -match '(?i)^(authorization|api[-_]?key|x-api-key|cookie|token|secret|password)$') {
                    $errors.Add((New-OmniRouteIssue -Path "$providerPath.headers.$headerName" -Message 'Sensitive headers must use apiKeyEnv.'))
                }
                if ($headerValue -match '[\r\n]') {
                    $errors.Add((New-OmniRouteIssue -Path "$providerPath.headers.$headerName" -Message 'Header values cannot contain CR or LF.'))
                }
                $headers[$headerName] = $headerValue
            }
        }
        elseif ($null -ne $headersRaw) {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.headers" -Message 'Must be an object.'))
        }

        $providerTimeoutSeconds = [int](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'timeoutSeconds' -Default $requestTimeoutSeconds)
        if ($providerTimeoutSeconds -lt 1 -or $providerTimeoutSeconds -gt 3600) {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.timeoutSeconds" -Message 'Must be from 1 to 3600 seconds.'))
            $providerTimeoutSeconds = $requestTimeoutSeconds
        }

        $priority = [int](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'priority' -Default 0)
        if ($priority -lt -10000 -or $priority -gt 10000) {
            $errors.Add((New-OmniRouteIssue -Path "$providerPath.priority" -Message 'Must be from -10000 to 10000.'))
            $priority = 0
        }

        $providers[$id] = @{
            id                 = $id
            type               = $type
            baseUrl            = $baseUrl
            apiKeyEnv          = $apiKeyEnv
            apiKeyHeader       = $apiKeyHeader
            apiKeyPrefix       = $apiKeyPrefix
            priority           = $priority
            enabled            = [bool](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'enabled' -Default $true)
            timeoutSeconds     = $providerTimeoutSeconds
            headers            = $headers
            models             = @(ConvertTo-OmniRouteStringArray -Value (Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'models' -Default @()))
            healthPath         = [string](Get-OmniRouteDictValue -Dictionary $providerRaw -Name 'healthPath' -Default '')
            capabilities       = $capabilities
        }
    }

    $routesRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'routes' -Default @{}
    $routes = @{}
    if ($routesRaw -isnot [System.Collections.IDictionary]) {
        $errors.Add((New-OmniRouteIssue -Path 'routes' -Message 'Must be an object mapping model patterns to provider arrays.'))
    }
    else {
        foreach ($pattern in @($routesRaw.Keys)) {
            $candidateProviders = @(ConvertTo-OmniRouteStringArray -Value $routesRaw[$pattern])
            if ($candidateProviders.Count -eq 0) {
                $errors.Add((New-OmniRouteIssue -Path "routes.$pattern" -Message 'Must contain at least one provider.'))
                continue
            }
            foreach ($candidate in $candidateProviders) {
                if (-not $providers.Contains($candidate)) {
                    $errors.Add((New-OmniRouteIssue -Path "routes.$pattern" -Message "Provider '$candidate' does not exist."))
                }
            }
            $routes[[string]$pattern] = $candidateProviders
        }
    }
    if (-not $routes.Contains('*')) {
        $warnings.Add((New-OmniRouteIssue -Path 'routes.*' -Message 'No wildcard route is defined; unmatched models will fail.'))
    }

    $aliasesRaw = Get-OmniRouteDictValue -Dictionary $RawConfig -Name 'aliases' -Default @{}
    $aliases = @{}
    if ($aliasesRaw -isnot [System.Collections.IDictionary]) {
        $errors.Add((New-OmniRouteIssue -Path 'aliases' -Message 'Must be an object mapping aliases to model IDs.'))
    }
    else {
        foreach ($alias in @($aliasesRaw.Keys)) {
            $target = [string]$aliasesRaw[$alias]
            if ([string]::IsNullOrWhiteSpace($target)) {
                $errors.Add((New-OmniRouteIssue -Path "aliases.$alias" -Message 'Alias target cannot be empty.'))
            }
            else {
                $aliases[[string]$alias] = $target
            }
        }
    }

    return @{
        sourcePath            = $SourcePath
        isExample             = ([System.IO.Path]::GetFileName($SourcePath) -ieq 'omniroute.example.json')
        listen                = $listen
        port                  = $port
        requestTimeoutSeconds = $requestTimeoutSeconds
        maxRequestBodyBytes   = $maxRequestBodyBytes
        healthCacheSeconds    = $healthCacheSeconds
        retry                 = $retry
        circuitBreaker        = $breaker
        fallbackOnStatus      = @($fallbackOnStatus | ForEach-Object { [int]$_ })
        logging               = $logging
        server                = $server
        http                  = $http
        providers             = $providers
        routes                = $routes
        aliases               = $aliases
        errors                = @($errors)
        warnings              = @($warnings)
    }
}

function Test-OmniRouteConfig {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$BasePath = (Get-Location).Path
    )

    $resolved = $null
    try {
        $resolved = Resolve-OmniRouteConfigPath -Path $Path -BasePath $BasePath
        $raw = Read-OmniRouteConfigFile -Path $resolved
        $config = ConvertTo-OmniRouteConfig -RawConfig $raw -SourcePath $resolved
        $errors = @($config.errors)
        $warnings = @($config.warnings)
        return [pscustomobject]@{
            valid      = ($errors.Count -eq 0)
            sourcePath = $resolved
            errors     = $errors
            warnings   = $warnings
            config     = $config
        }
    }
    catch {
        return [pscustomobject]@{
            valid      = $false
            sourcePath = $resolved
            errors     = @((New-OmniRouteIssue -Path 'config' -Message $_.Exception.Message))
            warnings   = @()
            config     = $null
        }
    }
}

function Get-OmniRouteConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path,
        [string]$BasePath = (Get-Location).Path
    )

    $result = Test-OmniRouteConfig -Path $Path -BasePath $BasePath
    if (-not $result.valid) {
        $details = @($result.errors | ForEach-Object { "$($_.path): $($_.message)" }) -join '; '
        throw "Invalid OmniRoute configuration: $details"
    }
    return $result.config
}

function Get-OmniRouteProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Id
    )
    if ($Config.providers.Contains($Id)) { return $Config.providers[$Id] }
    return $null
}

function Get-OmniRouteApiKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Provider)

    if ([string]::IsNullOrWhiteSpace([string]$Provider.apiKeyEnv)) { return '' }
    $value = [Environment]::GetEnvironmentVariable([string]$Provider.apiKeyEnv)
    if ($null -eq $value) { return '' }
    return [string]$value
}
