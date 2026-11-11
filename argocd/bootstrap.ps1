[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName,

    [ValidatePattern('^https://[A-Za-z0-9.-]+/?$')]
    [string]$AppConfigurationEndpoint,

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$AppConfigurationClientId,

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$AppConfigurationTenantId,

    [Parameter(Mandatory, ParameterSetName = 'Render')]
    [switch]$RenderOnly
)

$ErrorActionPreference = 'Stop'

if (($AppConfigurationEndpoint -or $AppConfigurationClientId -or $AppConfigurationTenantId) -and
    (-not $AppConfigurationEndpoint -or -not $AppConfigurationClientId -or -not $AppConfigurationTenantId)) {
    throw 'Specify AppConfigurationEndpoint, AppConfigurationClientId and AppConfigurationTenantId together.'
}

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

if ($AppConfigurationEndpoint) {
    $appConfigurationTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'appconfiguration.yaml') -Raw
    $appConfigurationManifest = $appConfigurationTemplate.Replace('${APP_CONFIGURATION_ENDPOINT}', $AppConfigurationEndpoint).
        Replace('${APP_CONFIGURATION_CLIENT_ID}', $AppConfigurationClientId).
        Replace('${APP_CONFIGURATION_TENANT_ID}', $AppConfigurationTenantId)
    $manifest = "$appConfigurationManifest`n---`n$manifest"
}

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

    $command = 'kubectl wait --for=condition=Established --timeout=120s crd/applications.argoproj.io && kubectl apply -f application.yaml && kubectl get application lovable-components --namespace argocd -o name'
    if ($AppConfigurationEndpoint) {
        $command = "kubectl wait --for=condition=Established --timeout=120s crd/azureappconfigurationproviders.azconfig.io && $command"
        $command += " && kubectl wait --for=jsonpath='{.status.phase}'=Complete azureappconfigurationprovider/lovable-appconfig --namespace lovable --timeout=600s && kubectl get configmap lovable-config --namespace lovable -o name"
    }

    $authorizationWait = @'
attempt=0
until kubectl auth can-i get customresourcedefinitions.apiextensions.k8s.io; do
    if [ "$attempt" -ge 30 ]; then
        echo "Bootstrap identity cannot read cluster-scoped CRDs after 300 seconds. Verify its Azure Kubernetes Service RBAC Cluster Admin assignment on this AKS cluster." >&2
        exit 1
    fi
    echo "Waiting for AKS Kubernetes RBAC propagation..."
    sleep 10
    attempt=$((attempt + 1))
done
'@
    $command = "$authorizationWait`n$command"

    $result = Invoke-AzAksRunCommand -ResourceGroupName $ResourceGroupName -Name $ClusterName `
        -Command $command `
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
