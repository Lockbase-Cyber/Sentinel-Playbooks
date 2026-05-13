# Testing

Three gates: **pre-deploy** (run locally before committing), **post-deploy smoke test** (read-only Graph call), and **end-to-end** (a real Sentinel incident driving a real MDI action against a real non-prod AD user).

This repo has no CI — all pre-deploy gates run on your machine.

## Pre-deploy gates

Run all of these before opening a PR.

### Bicep build clean (warnings-as-errors)

```powershell
az bicep build --file mdi-disable-playbook/infra/main.bicep --outdir mdi-disable-playbook/infra
```

Expected: exit code 0 and no stderr. Any warning (BCP*, secure-output, etc.) is a blocker. The build also regenerates `infra/main.json` — stage it in the same commit as the Bicep change, or the next Deploy-to-Azure click will use a stale template.

### Workflow JSON schema validation

```powershell
pwsh -File mdi-disable-playbook/infra/workflow/schema-validate.ps1
```

Expected: `workflow.json: OK`. The script parses `workflow.json` and validates it against the Logic Apps Consumption workflow definition schema. It catches malformed expressions and unknown action types that the ARM deploy would otherwise surface as a runtime 400.

### arm-ttk (optional but recommended)

```powershell
git clone --depth 1 https://github.com/Azure/arm-ttk.git $env:TEMP/arm-ttk
Import-Module $env:TEMP/arm-ttk/arm-ttk/arm-ttk.psd1
Test-AzTemplate -TemplatePath mdi-disable-playbook/infra/main.json
```

Expected: all tests pass. The Azure Resource Manager template toolkit catches the standard family of template anti-patterns (hard-coded locations, missing description metadata, secure parameter leaks). Skip if you're in a hurry — `az deployment group what-if` catches the most important issues at deploy time.

### `az deployment group what-if`

```powershell
$workspaceId = "/subscriptions/<SUB>/resourceGroups/<WS-RG>/providers/Microsoft.OperationalInsights/workspaces/<WS-NAME>"
az deployment group what-if `
  -g <RG> `
  --template-file mdi-disable-playbook/infra/main.json `
  --parameters sentinelWorkspaceResourceId=$workspaceId
```

Expected output set:
- One `Microsoft.Logic/workflows` (`Create` on first deploy, `Modify`/`NoChange` on subsequent).
- One `Microsoft.Web/connections` (`azuresentinel`, `kind: V1`, MI-auth via `parameterValueType: Alternative`).
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

### 2026-05-12 — Not yet executed

The implementation work (Tasks 1–11) was completed unattended on this date. Task 12's end-to-end smoke test was **not** run, for two reasons:

1. **Authentication.** `az login` requires interactive sign-in (device code or browser) and cannot be performed unattended without a service principal — and the whole point of this playbook is to deploy *without* SP secrets, so we don't want one.
2. **Destructive operations gated.** The project-scoped `.claude/settings.local.json` denies `az deployment group create`, `az rest --method POST/PUT/DELETE`, `az identity create`, and `az role assignment create` so that no live Azure mutation happens without explicit operator approval.

### Operator checklist on return

Before wiring an Automation Rule against any production-scope Sentinel incidents, run the full E2E exactly once in the sandbox. The steps below assume the operator is logged into the sandbox subscription and has `Contributor` on the target resource group.

1. **Verify the Deploy-to-Azure badge URL** in `mdi-disable-playbook/README.md` points at the correct fork (currently `Lockbase-Cyber/Sentinel-Playbooks` on `main`). If you forked elsewhere, update both the `uri` and `createUIDefinitionUri` segments accordingly.
2. **Click the Deploy-to-Azure badge** (or run the manual `az deployment group create` command from the README). On the basics page, pick the subscription, resource group, and Sentinel-onboarded Log Analytics workspace. Accept the defaults on the Playbook settings page.
3. **After the deployment succeeds**, fetch the Logic App's managed-identity principal ID:
   ```bash
   az deployment group show -g <RG> -n <DEPLOYMENT-NAME> \
     --query properties.outputs.managedIdentityPrincipalId.value -o tsv
   ```
4. **Grant Graph permissions** to the Logic App MI via `scripts/grant-graph-permissions.sh` in Cloud Shell (or `.ps1` locally). Verify with:
   ```bash
   az rest --method GET \
     --uri "https://graph.microsoft.com/v1.0/servicePrincipals/<MI_PRINCIPAL_ID>/appRoleAssignments"
   ```
   Expect both `SecurityIdentitiesAccount.Read.All` and `SecurityIdentitiesUserActions.ReadWrite.All` in the response.
5. **Assign MDI URBAC role** in the Defender portal per [permissions.md](./permissions.md). Wait ~5 minutes for propagation.
6. **Run `test-invoke.ps1`** against a known test SID:
   ```powershell
   pwsh -File mdi-disable-playbook/scripts/test-invoke.ps1 -TestSid "S-1-5-21-...-1234"
   ```
   Confirm the response shape matches what the workflow expects.
7. **Fire the synthetic incident** via Path A or Path B above. Verify all four checks under "Verification" (run history, incident comment, Defender Action Center, on-prem AD).
8. **Rollback** the test account per the Rollback section.
9. **Record results here.** Replace this checklist with the actual run log, including: sandbox subscription ID, test user identifier (no SID in the committed log — PII), date/time, run-trace branch hit (`BySid` / `ByAad`), Action Center actor + verbs, on-prem AD state delta.

Until this section is updated with a real run log, **do not** wire an Automation Rule to non-test analytics rules.
