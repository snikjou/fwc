#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Full deploy: provisions all Azure infrastructure and publishes the
    Logic App Standard workflow.

.DESCRIPTION
    Steps:
      1. az login (browser pop-up, satisfies MFA)
      2. Set target subscription
      3. Create / reuse resource group
      4. Bicep what-if validation
      5. Bicep deployment
      6. Build workflow zip package
      7. Zip-deploy to Logic App Standard
      8. Print portal URL

.PARAMETER SubscriptionId
    Azure subscription ID to deploy into.

.PARAMETER ResourceGroup
    Target resource group name (created if not present).

.PARAMETER Location
    Azure region. Default: eastus

.PARAMETER OpenAiEndpoint
    Azure OpenAI endpoint URL. Example: https://myoai.openai.azure.com

.EXAMPLE
    ./deploy.ps1 `
        -SubscriptionId aacf1513-0c88-464f-b867-28bb517bda41 `
        -ResourceGroup  rg-agreement-dev `
        -OpenAiEndpoint https://myoai.openai.azure.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = 'eastus',

    [Parameter(Mandatory)]
    [string]$OpenAiEndpoint,

    [string]$EnvironmentName = 'dev',
    [string]$AppName = 'agreement-extraction'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir    = $PSScriptRoot
$repoRoot     = Split-Path $scriptDir -Parent
$infraDir     = Join-Path $repoRoot 'infra'
$workflowDir  = Join-Path $repoRoot 'logicapp' 'agreement-extraction'
$deployTmp    = Join-Path $repoRoot '.deploy' 'logicapp'
$zipPath      = Join-Path $repoRoot '.deploy' 'logicapp.zip'
$paramFile    = Join-Path $infraDir 'main.bicepparam'
$bicepFile    = Join-Path $infraDir 'main.bicep'

# ─────────────────────────────────────────────────────────────
# 1. Login (opens browser, handles MFA)
# ─────────────────────────────────────────────────────────────
Write-Host "`n[1/8] Logging in to Azure..." -ForegroundColor Cyan
az login --output none
if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }

# ─────────────────────────────────────────────────────────────
# 2. Set subscription
# ─────────────────────────────────────────────────────────────
Write-Host "`n[2/8] Setting subscription $SubscriptionId..." -ForegroundColor Cyan
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription $SubscriptionId." }

# ─────────────────────────────────────────────────────────────
# 3. Ensure resource group
# ─────────────────────────────────────────────────────────────
Write-Host "`n[3/8] Ensuring resource group '$ResourceGroup' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create/confirm resource group." }

# ─────────────────────────────────────────────────────────────
# 4. Bicep what-if (preview)
# ─────────────────────────────────────────────────────────────
Write-Host "`n[4/8] Running Bicep what-if preview..." -ForegroundColor Cyan
az deployment group what-if `
    --name "agreement-extraction-deploy" `
    --resource-group $ResourceGroup `
    --template-file $bicepFile `
    --parameters $paramFile `
    --parameters openAiEndpoint=$OpenAiEndpoint environmentName=$EnvironmentName appName=$AppName location=$Location
if ($LASTEXITCODE -ne 0) { throw "Bicep what-if failed – review errors above." }

Write-Host "`nProceed with deployment? (Y/N): " -NoNewline -ForegroundColor Yellow
$answer = Read-Host
if ($answer -notmatch '^[Yy]') { Write-Host "Deployment cancelled."; exit 0 }

# ─────────────────────────────────────────────────────────────
# 5. Bicep deployment
# ─────────────────────────────────────────────────────────────
Write-Host "`n[5/8] Deploying Bicep template..." -ForegroundColor Cyan
$deployOutput = az deployment group create `
    --name "agreement-extraction-deploy" `
    --resource-group $ResourceGroup `
    --template-file $bicepFile `
    --parameters $paramFile `
    --parameters openAiEndpoint=$OpenAiEndpoint environmentName=$EnvironmentName appName=$AppName location=$Location `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed." }

$logicAppName = $deployOutput.properties.outputs.logicAppName.value
$logicAppUrl  = $deployOutput.properties.outputs.logicAppUrl.value
Write-Host "  Logic App: $logicAppName" -ForegroundColor Green
Write-Host "  URL:       $logicAppUrl" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# 6. Build workflow zip package
# ─────────────────────────────────────────────────────────────
Write-Host "`n[6/8] Building workflow zip package..." -ForegroundColor Cyan
if (Test-Path $deployTmp) { Remove-Item -Recurse -Force $deployTmp }
New-Item -ItemType Directory -Path $deployTmp | Out-Null

Copy-Item -Recurse -Force $workflowDir (Join-Path $deployTmp 'agreement-extraction')

$hostJson = @'
{
  "version": "2.0",
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle.Workflows",
    "version": "[1.*, 2.0.0)"
  }
}
'@
Set-Content -Path (Join-Path $deployTmp 'host.json') -Value $hostJson -Encoding utf8

if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path "$deployTmp/*" -DestinationPath $zipPath -Force
Write-Host "  Package: $zipPath" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# 7. Zip-deploy to Logic App Standard
# ─────────────────────────────────────────────────────────────
Write-Host "`n[7/8] Deploying workflow to $logicAppName..." -ForegroundColor Cyan
az webapp deploy `
    --resource-group $ResourceGroup `
    --name $logicAppName `
    --src-path $zipPath `
    --type zip `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Workflow zip-deploy failed." }

# ─────────────────────────────────────────────────────────────
# 8. Summary
# ─────────────────────────────────────────────────────────────
Write-Host "`n[8/8] Deployment complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Logic App name : $logicAppName"
Write-Host "  Portal URL     : https://portal.azure.com/#resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$logicAppName"
Write-Host "  App URL        : $logicAppUrl"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open the portal URL above and go to 'Workflows' to verify 'agreement-extraction' is listed."
Write-Host "  2. Add API Connections for 'Azure Blob Storage' and 'Azure Cosmos DB' in the Logic App Designer."
Write-Host "  3. Grant the Logic App managed identity 'Cosmos DB Built-in Data Contributor' on your Cosmos account."
Write-Host "  4. Upload a PDF to the '$($deployOutput.properties.outputs.blobContainerName.value)' container to trigger the workflow."
