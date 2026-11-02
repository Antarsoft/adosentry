# Repository rules — Bicep on Azure

This repository holds Bicep templates and modules for Azure infrastructure, deployed with `az deployment` in incremental mode, with one parameter file (`.bicepparam` or JSON) per environment. Review `.bicep`, `.bicepparam`, parameter JSON and `bicepconfig.json` changes according to the rules below.

## Bicep rules

### Secrets

1. A parameter that carries a password, key, token or connection string without `@secure()` is WARNING. A secure parameter with a literal default value, or a secret value in a parameter file, is CRITICAL.
2. An output that returns a secret (`listKeys()`, `listConnectionStrings()`, a connection string, a SAS token, a secure parameter) is CRITICAL: outputs are stored in plain text in the deployment history. Write the secret to Key Vault or have the app use its managed identity.
3. A secret passed in `deploymentScripts` arguments or environment variables without `secureValue` is WARNING.

### Destructive and state-changing deployments

1. Changing the `name` of a stateful resource (storage account, database, key vault, Cosmos DB account) deploys a new, empty resource and points dependants at it; the old one keeps the data. That is CRITICAL unless the change is clearly a planned migration.
2. Changing a property that cannot be updated in place (for example a storage account's `kind` downgrade, a Cosmos DB account's partition key, a SQL server's `administratorLogin`) is WARNING.
3. Switching a deployment to `--mode Complete`, or removing a resource lock on production, is CRITICAL.

### Network exposure and encryption

1. `publicNetworkAccess: 'Enabled'`, a firewall rule for `0.0.0.0`–`255.255.255.255`, `allowBlobPublicAccess: true`, or an NSG rule from `*` / `Internet` to a management or database port is CRITICAL in production and WARNING elsewhere.
2. `minimumTlsVersion` or `minTlsVersion` below 1.2, `supportsHttpsTrafficOnly: false` or `httpsOnly: false` is WARNING.
3. Turning off Key Vault purge protection or soft delete on a production vault is WARNING.

### Identity and access

1. A role assignment for `Owner`, `Contributor` or `User Access Administrator`, or one at subscription or management-group scope, where a narrower role would do, is WARNING.
2. A role assignment `name` that is not a deterministic `guid()` of its scope, principal and role (for example `newGuid()` or a plain string) is WARNING: redeployments fail or duplicate the assignment.
3. Turning local or key auth back on (`disableLocalAuth: false`, `allowSharedKeyAccess: true`) where the rest of the template uses Entra ID is WARNING.

### API versions and modules

1. A `-preview` API version on a production resource, where a stable one exists, is WARNING.
2. A registry module reference without a pinned version tag is WARNING.

### Environment parity

1. A change made in one environment's parameter file but not the others, when it is clearly meant for all of them, is WARNING.

## Conventions to respect

`az bicep build` and the Bicep linter run in CI; do not comment on formatting or on what the linter already reports (unused parameters, unnecessary `dependsOn`, `resourceId` style). Prefer the naming, tagging and module patterns already used in the repository.
