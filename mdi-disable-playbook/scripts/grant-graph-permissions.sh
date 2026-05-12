#!/usr/bin/env bash
# Grants the MDI playbook Graph app permissions to the Logic App's managed identity.
#
# Run this in Azure Cloud Shell (or any logged-in Azure CLI session) once,
# post-deploy, signed in as a Privileged Role Administrator or Global Admin.
#
# The Logic App's MI principal ID is emitted as the `managedIdentityPrincipalId`
# output of the main deployment. Find it in the portal under Deployments → outputs,
# or run:
#   az deployment group show -g <RG> -n <DEPLOYMENT-NAME> \
#     --query properties.outputs.managedIdentityPrincipalId.value -o tsv
#
# Usage:
#   ./grant-graph-permissions.sh <LOGIC_APP_MI_PRINCIPAL_ID>

set -euo pipefail

mi_principal_id="${1:?Usage: $0 <LOGIC_APP_MI_PRINCIPAL_ID>}"

graph_app_id="00000003-0000-0000-c000-000000000000"
roles=(
  "SecurityIdentitiesAccount.Read.All"
  "SecurityIdentitiesUserActions.ReadWrite.All"
)

echo "Looking up Microsoft Graph service principal..."
graph_sp_id=$(az ad sp show --id "$graph_app_id" --query id -o tsv)

for role_name in "${roles[@]}"; do
  echo
  echo "Processing app role: $role_name"
  role_id=$(az ad sp show --id "$graph_app_id" \
    --query "appRoles[?value=='$role_name'].id | [0]" -o tsv)
  if [[ -z "$role_id" ]]; then
    echo "  ERROR: app role '$role_name' not found on Microsoft Graph SP" >&2
    exit 1
  fi

  # Idempotency: skip if already assigned.
  existing=$(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mi_principal_id}/appRoleAssignments" \
    --query "value[?appRoleId=='${role_id}' && resourceId=='${graph_sp_id}'] | [0].id" -o tsv 2>/dev/null || true)

  if [[ -n "$existing" ]]; then
    echo "  Already granted (assignment id: $existing). Skipping."
    continue
  fi

  body=$(cat <<EOF
{
  "principalId": "${mi_principal_id}",
  "resourceId": "${graph_sp_id}",
  "appRoleId": "${role_id}"
}
EOF
)

  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mi_principal_id}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "$body" > /dev/null

  echo "  Granted."
done

echo
echo "Done. Verify in the Entra portal: Enterprise applications → (Logic App MI) → Permissions."
