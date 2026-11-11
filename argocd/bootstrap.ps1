[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [switch]$RenderOnly
)

$ErrorActionPreference = 'Stop'

$null = Get-Command az -ErrorAction Stop
$registryOutput = & az acr list --resource-group $ResourceGroupName --query '[].loginServer' --output json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Failed to list container registries in resource group '$ResourceGroupName' (Azure CLI exit code $LASTEXITCODE)."
}

$registries = @($registryOutput | ConvertFrom-Json -ErrorAction Stop)
if ($registries.Count -ne 1) {
    throw "Expected exactly one container registry in resource group '$ResourceGroupName', but found $($registries.Count)."
}

$registryUrl = $registries[0]
if ($registryUrl -isnot [string] -or $registryUrl -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?$') {
    throw 'The discovered container registry login server must be a hostname with an optional port, without a scheme, path, or whitespace.'
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
