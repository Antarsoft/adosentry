# Repository rules — Terraform on Azure

This repository holds Terraform 1.5+ for Azure infrastructure (the `azurerm` 4.x and `azapi` providers), with one variable file per environment. Review `.tf`, `.tfvars` and `.tftest.hcl` changes according to the rules below.

## Terraform rules

### Destructive changes and state safety

1. A change that forces replacement of a stateful resource (database, storage account, key vault, Cosmos DB account, Service Bus namespace, disk) is CRITICAL. That includes changing its `name`, `location`, or another argument that cannot be updated in place, and moving it without a `moved` block.
2. Removing `prevent_destroy`, a management lock or a `delete_lock` on a production resource is CRITICAL.
3. Renaming a resource or module address, or switching between `count` and `for_each`, without a `moved` block is WARNING: Terraform destroys and recreates it.
4. A `removed` block for a stateful resource without `lifecycle { destroy = false }` is WARNING.
5. Changing the backend block or the state key is WARNING.

### Secrets

1. A secret value in `.tf` or `.tfvars` (passwords, keys, connection strings, SAS tokens, client secrets) is CRITICAL; use Key Vault references, pipeline variables or managed identities.
2. A variable or output that carries a secret without `sensitive = true` is WARNING.

### Network exposure and encryption

1. An inbound security rule from `*`, `0.0.0.0/0` or `Internet` to a management port (22, 3389, 5985, 5986) or a database port is CRITICAL.
2. Turning on public network access (`public_network_access_enabled = true`, a `0.0.0.0` firewall rule, `allow_nested_items_to_be_public = true`) is CRITICAL in production and WARNING elsewhere.
3. `min_tls_version` below 1.2, `https_only = false`, or `https_traffic_only_enabled = false` is WARNING.
4. Turning off Key Vault purge protection or shortening soft-delete retention on a production vault is WARNING.

### Identity and access

1. A new role assignment at subscription or management-group scope, or `Owner`, `Contributor` or `User Access Administrator` where a narrower role would do, is WARNING.
2. Turning local or key-based auth back on (`local_authentication_disabled = false`, `shared_access_key_enabled = true`) where the rest of the code uses Entra ID is WARNING.

### Versions and modules

1. A `required_providers` entry without a version constraint, or a constraint with no upper bound on the major version, is WARNING.
2. A module `source` from git or the registry without a pinned `ref` or `version` is WARNING.

### Environment parity

1. A change made to one environment's variable file but not the others, when it is clearly meant for all of them, is WARNING.

## Conventions to respect

`terraform fmt`, `terraform validate` and `tflint` run in CI; do not comment on formatting or on what they already check. Provider-managed secret attributes (such as `random_password.result` and `azurerm_key_vault_secret.value`) are already marked sensitive; do not flag them. Prefer the naming and tagging patterns already in the module.
