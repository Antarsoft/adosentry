package storage

import (
	"fmt"

	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

// CosmosConfig locates the container.
type CosmosConfig struct {
	Endpoint  string
	Key       string
	Database  string
	Container string
}

// OpenCosmos builds the container client. The client connects lazily, so
// this does not call Cosmos.
func OpenCosmos(cfg CosmosConfig) (*Cosmos, error) {
	cred, err := azcosmos.NewKeyCredential(cfg.Key)
	if err != nil {
		return nil, fmt.Errorf("invalid COSMOS_KEY: %w", err)
	}
	client, err := azcosmos.NewClientWithKey(cfg.Endpoint, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create cosmos client: %w", err)
	}
	container, err := client.NewContainer(cfg.Database, cfg.Container)
	if err != nil {
		return nil, fmt.Errorf("failed to get container client: %w", err)
	}
	return NewCosmos(container), nil
}
