# Repository rules — Terraform on Azure

This repository holds Terraform for Azure infrastructure. Review `.tf` and `.tfvars` changes according to the rules below.

## Terraform rules

### Destructive changes and state safety

1. A change that forces replacement of a stateful resource (database, storage account, key vault, Cosmos account) — renaming it, changing a `ForceNew` argument, or moving it without a `moved` block — is CRITICAL.
2. Removing `prevent_destroy` or a resource lock on a production resource is CRITICAL.
3. Renaming a resource or module address without a `moved` block is WARNING.

### Access, network exposure and secrets

1. A secret value in `.tf` or `.tfvars` is CRITICAL; use Key Vault references or pipeline variables.
2. Opening public network access, `0.0.0.0/0` rules, or disabling TLS or HTTPS-only is CRITICAL in production and WARNING elsewhere.
3. A new role assignment at subscription scope, or Owner / Contributor where a narrower role would do, is WARNING.

### Environment parity

1. A change applied to one environment's variables but not the others, when it is clearly meant for all, is WARNING.

## Conventions to respect

`terraform fmt` and `tflint` run in CI; do not comment on formatting.
