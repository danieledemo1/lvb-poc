[CmdletBinding()]
param(
    [switch]$RenderOnly
)

$ErrorActionPreference = 'Stop'

$registryUrl = $env:REGISTRY_URL
if ([string]::IsNullOrWhiteSpace($registryUrl)) {
    throw 'Set REGISTRY_URL to your private registry hostname, optionally including a port.'
}

if ($registryUrl -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?$') {
    throw 'REGISTRY_URL must be a hostname with an optional port, without a scheme, path, or whitespace.'
}

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'application.yaml') -Raw
$manifest = $template.Replace('${REGISTRY_URL}', $registryUrl)

if ($RenderOnly) {
    Write-Output $manifest
    return
}

$null = Get-Command kubectl -ErrorAction Stop
$manifest | & kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply the root Argo CD Application (kubectl exit code $LASTEXITCODE)."
}
