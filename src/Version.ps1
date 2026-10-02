Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OmniRouteVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return '0.2.0'
}

function Get-OmniRouteUserAgent {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'OmniRoute-PS/' + (Get-OmniRouteVersion)
}
