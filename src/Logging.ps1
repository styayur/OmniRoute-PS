Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-OmniRouteRedactedText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $redacted = $Text
    $sensitiveNames = 'authorization|api[-_]?key|x-api-key|cookie|token|secret|password'
    $redacted = [regex]::Replace(
        $redacted,
        "(?i)($sensitiveNames)(\s*[:=]\s*)([^\s,;]+)",
        '$1$2***'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)([?&](?:api[-_]?key|key|token|secret|password)=)[^&\s]+',
        '$1***'
    )
    return $redacted
}

function Format-OmniRouteLogData {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Data)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Data.Keys) {
        $value = $Data[$key]
        if ($null -eq $value) { continue }
        $text = ConvertTo-OmniRouteRedactedText -Text ([string]$value)
        if ($text -match '\s') { $text = '"' + $text.Replace('"', '\"') + '"' }
        $parts.Add(('{0}={1}' -f $key, $text))
    }
    return ($parts -join ' ')
}

function Write-OmniRouteLog {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data = @{},
        [ValidateSet('console', 'json')][string]$Format = 'console'
    )

    $safeMessage = ConvertTo-OmniRouteRedactedText -Text $Message
    if ($Format -eq 'json') {
        $record = [ordered]@{
            time    = [DateTimeOffset]::Now.ToString('o')
            level   = $Level
            message = $safeMessage
        }
        foreach ($key in $Data.Keys) {
            $value = $Data[$key]
            $record[$key] = if ($null -eq $value) { $null } else { ConvertTo-OmniRouteRedactedText -Text ([string]$value) }
        }
        $line = $record | ConvertTo-Json -Compress -Depth 6
    }
    else {
        $suffix = Format-OmniRouteLogData -Data $Data
        $line = '{0} {1} {2}' -f ([DateTimeOffset]::Now.ToString('HH:mm:ss')), $Level.Substring(0, 3), $safeMessage
        if (-not [string]::IsNullOrWhiteSpace($suffix)) { $line += " $suffix" }
    }

    if (-not (Get-Variable -Name OmniRouteLogLock -Scope Script -ErrorAction SilentlyContinue)) {
        $script:OmniRouteLogLock = [object]::new()
    }
    [System.Threading.Monitor]::Enter($script:OmniRouteLogLock)
    try {
        [Console]::Error.WriteLine($line)
    }
    finally {
        [System.Threading.Monitor]::Exit($script:OmniRouteLogLock)
    }
}
