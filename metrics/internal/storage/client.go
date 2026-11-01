package storage

import (
	"fmt"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

// CosmosConfig locates the container. Key is optional: when it is empty
// the service signs in with Microsoft Entra ID instead.
type CosmosConfig struct {
	Endpoint  string
	Key       string
	Database  string
	Container string
}

// AuthMode names how OpenCosmos authenticates, for the startup log.
func (c CosmosConfig) AuthMode() string {
	if c.Key != "" {
		return "account key (COSMOS_KEY)"
	}
	return "Microsoft Entra ID (DefaultAzureCredential)"
}

// OpenCosmos builds the container client.
//
// With COSMOS_KEY unset it uses azidentity.DefaultAzureCredential: the
// Container App's managed identity in Azure (set AZURE_CLIENT_ID for a
// user-assigned one), or a developer's Azure CLI sign-in locally. The
// identity needs the Cosmos DB Built-in Data Contributor role on the
// account. This is the only mode that works against the account in infra/,
// which disables key auth. The key stays as a fallback for other accounts
// and the local emulator.
//
// The client connects lazily, so this does not call Cosmos or Entra.
func OpenCosmos(cfg CosmosConfig) (*Cosmos, error) {
	if cfg.Key != "" {
		return openCosmos(cfg, nil, nil)
	}
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("COSMOS_KEY is unset and no Entra credential is available: %w", err)
	}
	return openCosmos(cfg, cred, nil)
}

// openCosmos uses the key when set, otherwise cred. opts may be nil.
func openCosmos(cfg CosmosConfig, cred azcore.TokenCredential, opts *azcosmos.ClientOptions) (*Cosmos, error) {
	var (
		client *azcosmos.Client
		err    error
	)
	if cfg.Key != "" {
		keyCred, kerr := azcosmos.NewKeyCredential(cfg.Key)
		if kerr != nil {
			return nil, fmt.Errorf("invalid COSMOS_KEY: %w", kerr)
		}
		client, err = azcosmos.NewClientWithKey(cfg.Endpoint, keyCred, opts)
	} else {
		client, err = azcosmos.NewClient(cfg.Endpoint, cred, opts)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to create cosmos client: %w", err)
	}
	container, err := client.NewContainer(cfg.Database, cfg.Container)
	if err != nil {
		return nil, fmt.Errorf("failed to get container client: %w", err)
	}
	return NewCosmos(container), nil
}
