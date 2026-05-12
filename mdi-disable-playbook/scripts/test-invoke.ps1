#requires -Version 7.0
<#
.SYNOPSIS
  Manual smoke test for the MDI playbook. Verifies Graph reachability and the
  shape of the identityAccounts response WITHOUT calling invokeAction.
.DESCRIPTION
  Run signed in as the Logic App MI (via az login --identity in a VM with the MI
  attached) or as a user account that has equivalent Graph perms granted ad hoc.

  Step 1 of post-deploy testing: prove the GET returns the expected shape.
  Step 2 (firing a synthetic incident) is portal-only - see docs/testing.md.
.PARAMETER TestSid
  A known SID of a test user observed by MDI. Do NOT pass an admin or service account.
.PARAMETER GraphBaseUrl
  Override for the Graph base URL (default: beta surface).
.EXAMPLE
  pwsh -File ./test-invoke.ps1 -TestSid "S-1-5-21-1111111111-2222222222-3333333333-1001"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $TestSid,

  [string] $GraphBaseUrl = 'https://graph.microsoft.com/beta/security/identities/identityAccounts'
)

$ErrorActionPreference = 'Stop'

# Get a Graph access token via current az login (works for user, SP, or MI).
$tokenJson = az account get-access-token --resource https://graph.microsoft.com -o json | ConvertFrom-Json
if (-not $tokenJson.accessToken) { throw 'Failed to acquire Graph access token via az.' }

$headers = @{
  Authorization = "Bearer $($tokenJson.accessToken)"
  Accept        = 'application/json'
}

$filter = "onPremisesSecurityIdentifier eq '$TestSid'"
$select = 'id,displayName,domain,onPremisesSecurityIdentifier,accounts'
$url    = "${GraphBaseUrl}?`$filter=$([System.Uri]::EscapeDataString($filter))&`$select=$select"

Write-Host "GET $url"
$resp = Invoke-RestMethod -Uri $url -Headers $headers -Method GET

$count = $resp.value.Count
Write-Host "Matches: $count"

if ($count -ne 1) {
  Write-Warning "Expected 1 match. Workflow's exactly-one branch will not engage."
  return
}

$ia = $resp.value[0]
Write-Host "identityAccount.id           : $($ia.id)"
Write-Host "identityAccount.displayName  : $($ia.displayName)"
Write-Host "identityAccount.domain       : $($ia.domain)"
Write-Host "Sub-accounts:"
foreach ($a in $ia.accounts) {
  Write-Host "  - provider=$($a.provider) identifier=$($a.identifier)"
}

$adSub = $ia.accounts | Where-Object { $_.provider -eq 'ActiveDirectory' }
if (-not $adSub) {
  Write-Warning 'No ActiveDirectory sub-account on this identityAccount. invokeAction would skip with "no AD subaccount".'
} else {
  Write-Host "AD sub-account identifier ready for invokeAction.accountId: $($adSub.identifier)"
}
