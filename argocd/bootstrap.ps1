[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName,

    [Parameter(Mandatory, ParameterSetName = 'Render')]
    [switch]$RenderOnly
)

$ErrorActionPreference = 'Stop'

$registries = @(Get-AzContainerRegistry -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
if ($registries.Count -ne 1) {
    throw "Expected exactly one container registry in resource group '$ResourceGroupName', but found $($registries.Count)."
}

$registryUrl = $registries[0].LoginServer
if ($registryUrl -isnot [string] -or $registryUrl -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?$') {
    throw 'The discovered container registry login server must be a hostname with an optional port, without a scheme, path, or whitespace.'
}

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'application.yaml') -Raw
$manifest = $template.Replace('${REGISTRY_URL}', $registryUrl)

if ($RenderOnly) {
    Write-Output $manifest
    return
}

$null = Get-Command Invoke-AzAksRunCommand -ErrorAction Stop
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop
$manifestPath = Join-Path $temporaryDirectory 'application.yaml'
$attachmentPath = Join-Path $temporaryDirectory 'context.zip'

try {
    [System.IO.File]::WriteAllText($manifestPath, $manifest, [System.Text.UTF8Encoding]::new($false))
    Compress-Archive -LiteralPath $manifestPath -DestinationPath $attachmentPath -ErrorAction Stop

    $result = Invoke-AzAksRunCommand -ResourceGroupName $ResourceGroupName -Name $ClusterName `
        -Command 'kubectl wait --for=condition=Established --timeout=120s crd/applications.argoproj.io && kubectl apply -f application.yaml && kubectl get application lovable-components --namespace argocd -o name' `
        -CommandContextAttachmentZip $attachmentPath -Force -ErrorAction Stop

    if ($null -eq $result -or $result.ProvisioningState -ne 'Succeeded' -or $null -eq $result.ExitCode -or $result.ExitCode -ne 0) {
        throw "AKS Run Command failed (state '$($result.ProvisioningState)', exit code '$($result.ExitCode)'). $($result.Logs)"
    }

    Write-Output $result.Logs
} finally {
    foreach ($path in @($manifestPath, $attachmentPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Remove-Item -LiteralPath $temporaryDirectory -Force
}
