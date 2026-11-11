$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$azureState = @{
    Registries = @([pscustomobject]@{ LoginServer = 'example.azurecr.io' })
    RegistryError = $null
    RegistryResourceGroup = $null
    InvokeError = $null
    InvokeCount = 0
    Result = [pscustomobject]@{ ProvisioningState = 'Succeeded'; ExitCode = 0; Logs = 'application.argoproj.io/lovable-components' }
    Request = $null
}

function Get-AzContainerRegistry {
    [CmdletBinding()]
    param([string]$ResourceGroupName)

    $azureState.RegistryResourceGroup = $ResourceGroupName
    if ($azureState.RegistryError) {
        throw $azureState.RegistryError
    }
    $azureState.Registries
}

function Invoke-AzAksRunCommand {
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$Name,
        [string]$Command,
        [string]$CommandContextAttachmentZip,
        [switch]$Force
    )

    $azureState.InvokeCount++
    $archive = [System.IO.Compression.ZipFile]::OpenRead($CommandContextAttachmentZip)
    try {
        $reader = [System.IO.StreamReader]::new($archive.GetEntry('application.yaml').Open())
        try {
            $azureState.Request = @{
                ResourceGroupName = $ResourceGroupName
                ClusterName = $Name
                Command = $Command
                Manifest = $reader.ReadToEnd()
                AttachmentPath = $CommandContextAttachmentZip
                Force = $Force.IsPresent
            }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $archive.Dispose()
    }

    if ($azureState.InvokeError) {
        throw $azureState.InvokeError
    }
    $azureState.Result
}

function kubectl {
    throw 'Bootstrap must not call local kubectl.'
}

function az {
    throw 'Bootstrap must use the PowerShell-native Azure commands.'
}

$manifest = & $bootstrap -ResourceGroupName 'test-resource-group' -RenderOnly
if (-not $manifest.Contains("value: 'example.azurecr.io'") -or $manifest.Contains('${REGISTRY_URL}') -or $manifest.Contains('AzureAppConfigurationProvider')) {
    throw 'Bootstrap did not render the discovered registry login server.'
}
if ($azureState.RegistryResourceGroup -ne 'test-resource-group' -or $azureState.InvokeCount -ne 0) {
    throw 'Render-only bootstrap must scope registry discovery to the requested group without invoking AKS.'
}

$cases = @(
    @{ Registries = @(); Error = '*found 0*' }
    @{ Registries = @([pscustomobject]@{ LoginServer = 'one.azurecr.io' }, [pscustomobject]@{ LoginServer = 'two.azurecr.io' }); Error = '*found 2*' }
    @{ Registries = @(); RegistryError = 'Registry lookup denied'; Error = '*Registry lookup denied*' }
    @{ Registries = @([pscustomobject]@{ LoginServer = 'https://example.azurecr.io' }); Error = '*login server must be a hostname*' }
)

foreach ($case in $cases) {
    $azureState.Registries = $case.Registries
    $azureState.RegistryError = $case.RegistryError
    $failure = $null
    try {
        $null = & $bootstrap -ResourceGroupName 'test-resource-group' -RenderOnly
    } catch {
        $failure = $_
    }

    if ($null -eq $failure -or $failure.Exception.Message -notlike $case.Error) {
        throw "Expected registry discovery failure '$($case.Error)'; received '$failure'."
    }
}

$azureState.Registries = @([pscustomobject]@{ LoginServer = 'example.azurecr.io' })
$azureState.RegistryError = $null
$output = & $bootstrap -ResourceGroupName 'test-resource-group' -ClusterName 'test-cluster'
$request = $azureState.Request
if ($request.ResourceGroupName -ne 'test-resource-group' -or $request.ClusterName -ne 'test-cluster' -or -not $request.Force) {
    throw 'AKS Run Command was not scoped to the requested cluster or was not noninteractive.'
}
if (-not $request.Manifest.Contains("value: 'example.azurecr.io'") -or $request.Manifest.Contains('${REGISTRY_URL}')) {
    throw 'AKS Run Command did not receive the rendered Application manifest.'
}
if (-not $request.Command.Contains('kubectl apply -f application.yaml') -or -not $request.Command.Contains('kubectl get application lovable-components --namespace argocd')) {
    throw 'AKS Run Command must apply and verify the root Application.'
}
foreach ($expected in @('until kubectl auth can-i get customresourcedefinitions.apiextensions.k8s.io', '"$attempt" -ge 30', 'sleep 10', 'exit 1')) {
    if (-not $request.Command.Contains($expected)) {
        throw "Bootstrap must wait for Kubernetes RBAC propagation with a bounded failure: missing '$expected'."
    }
}
if ($request.Command.IndexOf('kubectl auth can-i') -gt $request.Command.IndexOf('kubectl wait')) {
    throw 'Bootstrap must verify Kubernetes authorization before accessing CRDs.'
}
if ($output -ne $azureState.Result.Logs -or (Test-Path -LiteralPath (Split-Path $request.AttachmentPath))) {
    throw 'Bootstrap must return remote logs and remove its temporary attachments.'
}

$appConfigurationParameters = @{
    AppConfigurationEndpoint = 'https://test-store.azconfig.io'
    AppConfigurationClientId = '11111111-2222-3333-4444-555555555555'
    AppConfigurationTenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
}
$invokeCount = $azureState.InvokeCount
$configuredManifest = & $bootstrap -ResourceGroupName 'test-resource-group' -RenderOnly @appConfigurationParameters
if ($azureState.InvokeCount -ne $invokeCount -or -not $configuredManifest.Contains('kind: AzureAppConfigurationProvider')) {
    throw 'Render-only bootstrap must include App Configuration resources without invoking AKS when configured.'
}
$null = & $bootstrap -ResourceGroupName 'test-resource-group' -ClusterName 'test-cluster' @appConfigurationParameters
$request = $azureState.Request
foreach ($expected in @('kind: ServiceAccount', 'name: appconfig-provider', 'namespace: lovable', 'configMapName: lovable-config', 'keyFilter: lovableVersion', 'interval: 1m') + @($appConfigurationParameters.Values)) {
    if (-not $request.Manifest.Contains($expected)) {
        throw "The App Configuration manifest is missing '$expected'."
    }
}
if ($request.Manifest.Contains('${APP_CONFIGURATION_') -or -not $request.Manifest.Contains('kind: Application')) {
    throw 'App Configuration bootstrap must resolve all placeholders and preserve the root Application.'
}
foreach ($expected in @('crd/azureappconfigurationproviders.azconfig.io', "--for=jsonpath='{.status.phase}'=Complete", 'azureappconfigurationprovider/lovable-appconfig', 'kubectl get configmap lovable-config --namespace lovable')) {
    if (-not $request.Command.Contains($expected)) {
        throw "App Configuration bootstrap must wait for and verify synchronization: missing '$expected'."
    }
}
if (Test-Path -LiteralPath (Split-Path $request.AttachmentPath)) {
    throw 'App Configuration bootstrap did not remove temporary attachments.'
}

$invalidConfigurations = @(
    @{ AppConfigurationEndpoint = 'https://test-store.azconfig.io' }
    @{ AppConfigurationEndpoint = 'http://test-store.azconfig.io'; AppConfigurationClientId = $appConfigurationParameters.AppConfigurationClientId; AppConfigurationTenantId = $appConfigurationParameters.AppConfigurationTenantId }
    @{ AppConfigurationEndpoint = $appConfigurationParameters.AppConfigurationEndpoint; AppConfigurationClientId = 'invalid-client-id'; AppConfigurationTenantId = $appConfigurationParameters.AppConfigurationTenantId }
)
foreach ($parameters in $invalidConfigurations) {
    $failure = $null
    try {
        $null = & $bootstrap -ResourceGroupName 'test-resource-group' -RenderOnly @parameters
    } catch {
        $failure = $_
    }
    if ($null -eq $failure -or $failure.Exception.Message -notlike '*AppConfiguration*') {
        throw "Bootstrap must reject incomplete or invalid App Configuration parameters; received '$failure'."
    }
}

$cases = @(
    @{ Result = [pscustomobject]@{ ProvisioningState = 'Succeeded'; ExitCode = 1; Logs = 'kubectl apply failed' }; Error = '*exit code ''1''*kubectl apply failed*' }
    @{ Result = [pscustomobject]@{ ProvisioningState = 'Failed'; ExitCode = 0; Logs = 'Run Command failed' }; Error = '*state ''Failed''*' }
    @{ Result = [pscustomobject]@{ ProvisioningState = 'Succeeded'; ExitCode = $null; Logs = '' }; Error = '*AKS Run Command failed*' }
    @{ Result = $null; Error = '*AKS Run Command failed*' }
    @{ InvokeError = 'Run Command access denied'; Error = '*Run Command access denied*' }
)

foreach ($case in $cases) {
    $azureState.Result = $case.Result
    $azureState.InvokeError = $case.InvokeError
    $failure = $null
    try {
        $null = & $bootstrap -ResourceGroupName 'test-resource-group' -ClusterName 'test-cluster'
    } catch {
        $failure = $_
    }

    if ($null -eq $failure -or $failure.Exception.Message -notlike $case.Error) {
        throw "Expected Run Command failure '$($case.Error)'; received '$failure'."
    }
    if (Test-Path -LiteralPath (Split-Path $azureState.Request.AttachmentPath)) {
        throw 'Bootstrap did not clean up temporary files after Run Command failed.'
    }
}

$deployment = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\infra\deployment.json') -Raw | ConvertFrom-Json
$clusterAdminAssignment = @($deployment.resources | Where-Object {
    $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
    $_.properties.roleDefinitionId -eq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')]"
})
if ($clusterAdminAssignment.Count -ne 1 -or
    $clusterAdminAssignment[0].scope -ne "[resourceId('Microsoft.ContainerService/managedClusters', variables('clusterName'))]" -or
    $clusterAdminAssignment[0].properties.principalId -ne "[reference(variables('bootstrapIdentityId'), '2024-11-30').principalId]") {
    throw 'Bootstrap requires Kubernetes data-plane cluster-admin access scoped only to its AKS cluster and assigned to its managed identity.'
}
$deploymentScript = $deployment.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deploymentScripts' }
$assignmentDependency = "[extensionResourceId(resourceId('Microsoft.ContainerService/managedClusters', variables('clusterName')), 'Microsoft.Authorization/roleAssignments', variables('bootstrapClusterAdminRoleAssignmentName'))]"
if ($clusterAdminAssignment[0].name -ne "[variables('bootstrapClusterAdminRoleAssignmentName')]" -or
    $deploymentScript.dependsOn -notcontains $assignmentDependency) {
    throw 'The deployment script must depend on its Kubernetes data-plane role assignment.'
}

Write-Output 'PASS: registry discovery, render-only mode, private-cluster Run Command, Kubernetes RBAC and propagation checks, App Configuration rendering and synchronization checks, remote failures, and cleanup.'
