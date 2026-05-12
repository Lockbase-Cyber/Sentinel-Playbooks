# Permissions

The Logic App created by this playbook uses a **system-assigned managed identity** for every outbound call: Sentinel (comment back to incident), Microsoft Graph (list identityAccounts, invoke remediation), and the Logic App's own resource-group-scope reads via the Sentinel connector access policy. No client secrets, no app registrations, no key vault entries.

This document covers the four permission grants the MI needs and how each one is applied.

## Permission summary

| Permission | Scope | Granted by | Manual step? |
|---|---|---|---|
| Sentinel Responder (RBAC) | Resource group | `infra/modules/roleAssignments.bicep` | No (automatic on deploy) |
| `SecurityIdentitiesAccount.Read.All` (Graph app) | Tenant | `grant-graph-permissions.{sh,ps1}` OR `deploymentScripts` path | Yes by default (manual); No if advanced path |
| `SecurityIdentitiesUserActions.ReadWrite.All` (Graph app) | Tenant | same as above | same as above |
| MDI URBAC role with **Response (manage)** on **Identities** | Defender XDR | Operator, via Defender portal | Always manual |

## Sentinel Responder role assignment (automatic)

`infra/modules/roleAssignments.bicep` declares a `Microsoft.Authorization/roleAssignments` for the role definition `ab8e14d6-...` (Sentinel Responder) at the **resource group** scope, with `principalId = managedIdentityPrincipalId` of the Logic App. This is what allows the workflow to write `Add_comment_to_incident` against the Sentinel `Incidents - Comment` endpoint.

The role assignment requires the **deploying principal** (the OIDC GitHub Actions app, or the user running `az deployment group create` manually) to hold `Owner` or `User Access Administrator` on the target resource group. Without that, the deploy fails at this resource with a 403 — the rest of the resources will already have created, leaving you in a partial state. Run the deploy as a principal with role-assignment rights.

Verification:

```bash
az role assignment list \
  --assignee <MI_PRINCIPAL_ID> \
  --scope /subscriptions/<SUB>/resourceGroups/<RG> \
  --query "[?roleDefinitionName=='Microsoft Sentinel Responder']"
```

Expect a single object.

## Graph app permissions: the deploymentScript vs manual decision tree

The Logic App MI needs two Microsoft Graph **application** permissions (not delegated):

- **`SecurityIdentitiesAccount.Read.All`** — `GET /security/identities/identityAccounts`.
- **`SecurityIdentitiesUserActions.ReadWrite.All`** — `POST /security/identities/identityAccounts/{id}/invokeAction`.

These cannot be granted by the Logic App to itself, because granting an app role requires `AppRoleAssignment.ReadWrite.All` on Graph, which is itself a Graph app permission. There are two ways out of this chicken-and-egg:

### Path A — Manual grant after deploy (default)

`grantGraphPermissionsViaDeploymentScript = false` (the default). After deploy, an operator with `Privileged Role Administrator` or `Global Administrator` runs `scripts/grant-graph-permissions.sh` in Azure Cloud Shell or `scripts/grant-graph-permissions.ps1` locally. The script:

1. Resolves the Graph service principal (`appId = 00000003-0000-0000-c000-000000000000`).
2. Looks up the two role IDs by `value`.
3. POSTs `appRoleAssignments` for each, with `resourceId = <Graph SP objectId>`, `principalId = <LogicApp MI objectId>`, `appRoleId = <role guid>`.

**Tradeoff**: friction-free one-click deploy (the Deploy-to-Azure button in the README works for anyone), but every deploy needs a privileged human in the post-deploy loop.

### Path B — Bootstrap UAMI + `deploymentScripts` (advanced)

`grantGraphPermissionsViaDeploymentScript = true` plus `bootstrapManagedIdentityResourceId = /subscriptions/.../userAssignedIdentities/uami-...`. The Bicep `graphPermissions.bicep` module then runs a `Microsoft.Resources/deploymentScripts` resource impersonating the bootstrap UAMI (which already has `AppRoleAssignment.ReadWrite.All`) and grants the two roles inline as part of the ARM deployment.

**Tradeoff**: no human in the loop on deploy, but the bootstrap UAMI is a permanently-provisioned, tenant-power identity that needs treating as such (CA policies, audit alerting, no extraneous role assignments).

The decision is per-environment. Most public consumers of this repo should stick with Path A. Path B is the right call for an internal SOC team that owns a dev/prod CI flow and is comfortable owning the bootstrap UAMI's lifecycle.

## Bootstrap UAMI

Required only for Path B. **Create once per subscription** and reuse across every playbook in the repo that opts into the deploymentScripts path.

```powershell
$rg   = "REPLACE_ME"
$name = "uami-deploymentscript-graph-bootstrap"
$mi   = az identity create -g $rg -n $name -o json | ConvertFrom-Json

# One-time: grant AppRoleAssignment.ReadWrite.All on Microsoft Graph to $mi.principalId.
# The grant-graph-permissions.ps1 script can be invoked with the AppRoleAssignment role guid
# substituted in place of the playbook's two roles.
./scripts/grant-graph-permissions.ps1 `
  -LogicAppPrincipalId $mi.principalId `
  -RoleValues @('AppRoleAssignment.ReadWrite.All')
```

Note the resource ID (`$mi.id`) — that's the value to put into `bootstrapManagedIdentityResourceId` in your parameters file.

Operational guidance:

- Place the UAMI in a tightly-scoped resource group that the SOC team owns. Do **not** let arbitrary deployments use it; reference it explicitly from parameter files only.
- Audit `appRoleAssignments` on this UAMI quarterly. The only one that should be present is `AppRoleAssignment.ReadWrite.All`.
- Rotate by deleting and recreating — UAMIs don't have secrets to rotate, but having a cadence forces a review of who/what is referencing the resource ID.

## MDI URBAC role assignment

This is the gate Graph app permissions don't cover. The Graph layer accepts the `invokeAction` call as long as the MI has `SecurityIdentitiesUserActions.ReadWrite.All`, but MDI **then** enforces its own URBAC policy before queuing the AD write to the gMSA Action Account. Without URBAC, you'll see Graph 200 OKs and zero action in Defender Action Center.

### Portal steps

1. Defender portal → **Settings** → **Microsoft Defender XDR** → **Permissions and roles** → **Roles**.
2. **Create custom role** (or edit an existing one) with the **Response (manage)** permission group on the **Identities** data source.
3. **Scope**: choose `All identities`, or narrow if your environment requires scoping (e.g., only a specific OU's identities).
4. **Members**: **Add** → search for the Logic App MI by its `managedIdentityPrincipalId` (the value from `az deployment group show ... managedIdentityPrincipalId.value`). System-assigned MIs surface in the picker once they've propagated; allow a few minutes after deploy.
5. **Save**.

![MDI URBAC role assignment](images/mdi-urbac-role.png)

> Screenshot to be added when first deployed against a real tenant — this page intentionally ships with a placeholder. Capture the Defender XDR **Permissions and roles → Roles → \<your role\> → Members** view showing the Logic App MI present, with `Response (manage)` ticked on `Identities`.

### Why this can't be automated in Bicep

MDI URBAC is a Defender XDR control plane, not an Azure RBAC scope. There is no `Microsoft.Authorization/roleAssignments` analog and no first-party ARM resource type for it at the time of writing. Until Microsoft ships a manageable surface (Graph, ARM, or otherwise), this step stays manual. The README and the testing doc both flag this — don't claim the deploy is "done" until URBAC is in place.

## Verification

After both the manual Graph grant and the URBAC assignment, confirm:

### Graph app role assignments

```bash
miId="<MI_PRINCIPAL_ID>"
az rest --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miId/appRoleAssignments" \
  --query "value[].{resource:resourceDisplayName, role:appRoleId}" -o table
```

Expect two rows: one each for `SecurityIdentitiesAccount.Read.All` and `SecurityIdentitiesUserActions.ReadWrite.All`, both with `resourceDisplayName = Microsoft Graph`.

In PowerShell with Microsoft.Graph:

```powershell
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miId | 
  Where-Object { $_.ResourceDisplayName -eq 'Microsoft Graph' } |
  Select-Object AppRoleId, ResourceDisplayName, CreatedDateTime
```

### Sentinel Responder role assignment

```bash
az role assignment list --assignee $miId --query "[?roleDefinitionName=='Microsoft Sentinel Responder']" -o table
```

Expect a single row at the resource group scope.

### MDI URBAC (visual)

Defender portal → **Settings** → **Permissions and roles** → **Roles** → \<your role\> → **Members** — the MI should appear by its principal ID. There is no first-party API to query this from script today.

If all three checks pass, the MI is ready to run end-to-end. See [testing.md](./testing.md) for the smoke test that exercises the full path.
