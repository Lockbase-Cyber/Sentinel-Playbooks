# Testing

Three gates: **pre-deploy** (static analysis on the template), **post-deploy smoke test** (read-only Graph call), and **end-to-end** (a real Sentinel incident driving a real MDI action against a real non-prod AD user).

## Pre-deploy gates

Run all three before opening a PR. The first two are also enforced in CI by `.github/workflows/validate.yml`.

### Bicep build clean (warnings-as-errors)

```powershell
az bicep build --file mdi-disable-playbook/infra/main.bicep --outdir mdi-disable-playbook/infra
```

Expected: exit code 0 and no stderr. Any warning (BCP*, secure-output, etc.) blocks the PR. The build also regenerates `infra/main.json` — stage that in the same commit as any Bicep change, or the drift check will fail in CI.

### Workflow JSON schema validation

```powershell
pwsh -File mdi-disable-playbook/infra/workflow/schema-validate.ps1
```

Expected: `workflow.json: OK`. The script parses `workflow.json` and validates it against the Logic Apps Consumption workflow definition schema. It catches malformed expressions and unknown action types that the ARM deploy would otherwise surface as a runtime 400.

### arm-ttk

```powershell
Test-AzTemplate -TemplatePath mdi-disable-playbook/infra/main.json
```

Expected: all tests pass. The Azure Resource Manager template toolkit catches the standard family of template anti-patterns (hard-coded locations, missing description metadata, secure parameter leaks).

### `az deployment group what-if`

```powershell
az deployment group what-if `
  -g <RG> `
  --template-file mdi-disable-playbook/infra/main.json `
  --parameters @mdi-disable-playbook/infra/parameters/dev.parameters.json
```

Expected output set:
- One `Microsoft.Logic/workflows` (`Create` on first deploy, `Modify`/`NoChange` on subsequent).
- One `Microsoft.Web/connections` (`azuresentinel`).
- One `Microsoft.Logic/workflows/accessPolicies` (child of the workflow).
- One `Microsoft.Authorization/roleAssignments` (Sentinel Responder at RG scope).
- Optionally one `Microsoft.Resources/deploymentScripts` (only when `grantGraphPermissionsViaDeploymentScript = true`).

Anything else — especially app registrations, key vaults, or storage accounts beyond what `deploymentScripts` requires under the hood — is a regression. Investigate before deploying.

## Post-deploy smoke test (read-only)

`scripts/test-invoke.ps1` issues a single Graph `GET identityAccounts?$filter=onPremisesSecurityIdentifier eq '<sid>'` using the Logic App MI's token (via an `az rest` or `Connect-MgGraph` MI flow). It does **not** invoke any remediation action.

```powershell
pwsh -File mdi-disable-playbook/scripts/test-invoke.ps1 -TestSid "S-1-5-21-...-1234"
```

Expected: the script prints the matching `identityAccount` JSON with at least one `accounts` entry whose `provider == 'ActiveDirectory'` and an `identifier` matching the target SAM-account-name. If the response is empty, MDI has not observed that SID — pick a different test user that MDI's sensors do see.

This is the right gate to claim "MI has Graph perms" without writing to AD. Run it any time you re-grant Graph roles.

## End-to-end test

There is no good way to mock the MDI `invokeAction` call: the response is asynchronous, the actual AD write happens on a different host (the gMSA Action Account on an MDI sensor), and the verification surface is in Defender XDR's Action Center. **E2E test must use a real non-prod identity** observed by MDI in a non-production AD.

Set up:
- A non-prod AD user (`testuser-mdi-playbook` or similar) created in the same domain that MDI sensors are watching.
- Confirm via `test-invoke.ps1 -TestSid <that user's SID>` that MDI has indexed the account.
- Confirm `forcePasswordReset` will actually take effect — that means the user object does **not** have `PasswordNeverExpires` set. The MDI call returns 200 even when the AD attribute would silently no-op the reset, so this has to be verified out-of-band.

### Path A — "Run playbook" from the portal

Lowest-friction. Open any existing Sentinel incident in your sandbox workspace that already has the test user's `Account` entity (or create a synthetic incident — see Path B below for the API call). In the incident detail blade:

1. **Actions** → **Run playbook**.
2. Select the deployed Logic App.
3. Confirm.

The Logic App run trace will show the `BySid` (or `ByAad`) branch executing, the `ExactlyOne` case taken, and `Invoke_action` issued once per item in `actionsToEnable`.

### Path B — `az rest` against the Sentinel Incidents API

Useful when you don't have a clean existing incident or when you want a reproducible E2E gate in CI:

```powershell
$workspaceId = "<WORKSPACE-RESOURCE-ID>"
$incidentId  = [guid]::NewGuid().Guid
$body = @{
  properties = @{
    title = "MDI playbook E2E test"
    severity = "Low"
    status = "New"
    description = "Synthetic incident for MDI disable playbook smoke test."
  }
} | ConvertTo-Json -Depth 10

az rest --method put `
  --url "https://management.azure.com$workspaceId/providers/Microsoft.SecurityInsights/incidents/$incidentId?api-version=2024-03-01" `
  --body $body
```

Then attach an `Account` entity carrying the test user's SID to the incident (Sentinel → Incident → Entities → Add). Trigger the playbook via the Automation Rule (if configured) or via the Run playbook button.

## Verification

After triggering (either path), verify in this order:

1. **Logic App run history** (`Azure portal → Logic App → Runs history`): the latest run is `Succeeded`. Expand it and confirm:
   - `Switch_match_strategy` took the expected `BySid` or `ByAad` branch.
   - `Switch_on_match_count` hit `ExactlyOne`.
   - `Invoke_action` returned 200 once per action in `actionsToEnable`.
   - `Add_comment_to_incident` succeeded.
2. **Sentinel incident**: open the incident. There should be a new comment with a JSON code block containing the `actionResults` array — one entry per `(identityAccountId, action)` pair with `result: "ok"`.
3. **Defender XDR → Action Center → History**: the actions appear with `Actor = <Logic App MI principal id>` and the correct verb (`Disable user`, `Force password reset`). This is the only surface that confirms MDI actually queued the AD write — not just the Graph 200 OK.
4. **On-prem AD** (out-of-band check, log into a DC or run from a workstation with RSAT):
   ```powershell
   Get-ADUser testuser-mdi-playbook -Properties Enabled, PasswordLastSet, pwdLastSet
   ```
   `Enabled` should be `False` if `disable` was in `actionsToEnable`. `pwdLastSet` should be `0` (or `PasswordLastSet` very recent and `ChangePasswordAtNextLogon = $true`) if `forcePasswordReset` was in `actionsToEnable`.

If any of those four checks fails, the playbook is not done — see [permissions.md](./permissions.md) (most failures are MDI URBAC not being assigned) and the Logic App run trace.

## Rollback

After E2E, restore the test account so the next iteration of the test starts from a clean state:

```powershell
Enable-ADAccount -Identity testuser-mdi-playbook
Set-ADAccountPassword -Identity testuser-mdi-playbook -Reset `
  -NewPassword (ConvertTo-SecureString -AsPlainText "<temp-password>" -Force)
```

Then immediately re-run `test-invoke.ps1` to confirm the SID still resolves in MDI and you're ready to re-test.

## Mocking note

> **There is no good way to mock the MDI `invokeAction` call.** The endpoint is asynchronous on the MDI side, the AD write happens on a separate host, and the only authoritative result surface is the Defender Action Center. E2E **must** use a real non-prod identity. Stubbing `graphBaseUrl` to a local mock catches workflow-shape bugs but tells you nothing about end-to-end correctness.

## Smoke test results

_To be populated by Task 12 when the sandbox E2E is run._
