# Sentinel-Playbooks

A collection of Microsoft Sentinel playbooks deployed as Logic Apps via Bicep + GitHub Actions.

## Playbooks

| Playbook | Trigger | Purpose |
|---|---|---|
| [mdi-disable-playbook](./mdi-disable-playbook) | Sentinel incident | Disable on-prem AD account and/or force password reset via MDI Action Account |

## Conventions

- Each playbook is a self-contained subdirectory with its own `infra/`, `docs/`, `scripts/`, and `.github/workflows/`.
- All playbooks use system-assigned managed identity. No secrets in source.
- Deployment via OIDC-federated GitHub Actions; manual `az deployment group create` fallback documented per playbook.
