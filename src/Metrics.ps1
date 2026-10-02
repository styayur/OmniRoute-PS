Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OmniRouteMetricKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Labels = @{}
    )
    if ($Labels.Count -eq 0) { return $Name }
    $parts = foreach ($key in @($Labels.Keys | Sort-Object)) { "$key=$($Labels[$key])" }
    return $Name + '|' + ($parts -join ',')
}

function Add-OmniRouteMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Name,
        [long]$Value = 1,
        [hashtable]$Labels = @{}
    )
    $key = Get-OmniRouteMetricKey -Name $Name -Labels $Labels
    [System.Threading.Monitor]::Enter($State.metrics)
    try {
        $current = if ($State.metrics.ContainsKey($key)) { [long]$State.metrics[$key] } else { 0L }
        $State.metrics[$key] = $current + $Value
    }
    finally { [System.Threading.Monitor]::Exit($State.metrics) }
}

function Set-OmniRouteMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Name,
        [long]$Value,
        [hashtable]$Labels = @{}
    )
    $key = Get-OmniRouteMetricKey -Name $Name -Labels $Labels
    [System.Threading.Monitor]::Enter($State.metrics)
    try { $State.metrics[$key] = $Value }
    finally { [System.Threading.Monitor]::Exit($State.metrics) }
}

function Get-OmniRouteMetric {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Labels = @{}
    )
    $key = Get-OmniRouteMetricKey -Name $Name -Labels $Labels
    [System.Threading.Monitor]::Enter($State.metrics)
    try { if ($State.metrics.ContainsKey($key)) { return [long]$State.metrics[$key] } return 0L }
    finally { [System.Threading.Monitor]::Exit($State.metrics) }
}

function ConvertTo-OmniRoutePrometheusLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n')
}

function Get-OmniRouteMetrics {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State)
    $lines = [System.Collections.Generic.List[string]]::new()
    $simple = @(
        'omniroute_requests_total'
        'omniroute_requests_active'
        'omniroute_requests_queued'
        'omniroute_fallback_total'
        'omniroute_circuit_open_total'
        'omniroute_streams_active'
        'omniroute_request_duration_ms_sum'
        'omniroute_request_duration_ms_count'
    )
    foreach ($name in $simple) {
        $value = Get-OmniRouteMetric -State $State -Name $name
        $type = if ($name -in @('omniroute_requests_active', 'omniroute_requests_queued', 'omniroute_streams_active')) { 'gauge' } else { 'counter' }
        $lines.Add("# TYPE $name $type")
        $lines.Add("$name $value")
    }
    foreach ($key in @($State.metrics.Keys | Where-Object { $_ -like 'omniroute_provider_requests_total|*' } | Sort-Object)) {
        $parts = $key.Split('|', 2)
        $labelValue = $parts[1] -replace '^provider=', ''
        $lines.Add('omniroute_provider_requests_total{provider="' + (ConvertTo-OmniRoutePrometheusLabel -Value $labelValue) + '"} ' + $State.metrics[$key])
    }
    foreach ($key in @($State.metrics.Keys | Where-Object { $_ -like 'omniroute_provider_failures_total|*' } | Sort-Object)) {
        $parts = $key.Split('|', 2)
        $labelValue = $parts[1] -replace '^provider=', ''
        $lines.Add('omniroute_provider_failures_total{provider="' + (ConvertTo-OmniRoutePrometheusLabel -Value $labelValue) + '"} ' + $State.metrics[$key])
    }
    return ($lines -join "`n")
}
