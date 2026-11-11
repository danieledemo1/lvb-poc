$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$azureState = @{
    ExitCode = 0
    Output = '["example.azurecr.io"]'
    Arguments = @()
}

function az {
    $azureState.Arguments = @($args)
    $global:LASTEXITCODE = $azureState.ExitCode
    Write-Output $azureState.Output
}

function kubectl {
    throw 'Render-only bootstrap must not call kubectl.'
}

$manifest = & $bootstrap -ResourceGroupName 'test-resource-group' -RenderOnly
if (-not $manifest.Contains("value: 'example.azurecr.io'") -or $manifest.Contains('${REGISTRY_URL}')) {
    throw 'Bootstrap did not render the discovered registry login server.'
}
if (($azureState.Arguments -join ' ') -ne 'acr list --resource-group test-resource-group --query [].loginServer --output json --only-show-errors') {
    throw 'Registry discovery did not use the requested resource group and login-server query.'
}

$cases = @(
    @{ Output = '[]'; ExitCode = 0; Error = '*found 0*' }
    @{ Output = '["one.azurecr.io","two.azurecr.io"]'; ExitCode = 0; Error = '*found 2*' }
    @{ Output = ''; ExitCode = 1; Error = '*Azure CLI exit code 1*' }
    @{ Output = '["https://example.azurecr.io"]'; ExitCode = 0; Error = '*login server must be a hostname*' }
    @{ Output = 'not-json'; ExitCode = 0; Error = '*JSON*' }
)

foreach ($case in $cases) {
    $azureState.Output = $case.Output
    $azureState.ExitCode = $case.ExitCode
    $failure = $null
    try {
        $null = & $bootstrap -ResourceGroupName 'test-resource-group' -RenderOnly
    } catch {
        $failure = $_
    }

    if ($null -eq $failure -or $failure.Exception.Message -notlike $case.Error) {
        throw "Expected failure '$($case.Error)' for registry output '$($case.Output)'; received '$failure'."
    }
}

Write-Output 'PASS: registry discovery, resource-group scoping, rendering, and discovery failure cases.'
