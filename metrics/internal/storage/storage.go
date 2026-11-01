// Package storage is the metrics service's only contact with Cosmos DB.
//
// Handlers depend on the Store interface, so they can be tested with a
// fake, and the Cosmos details (partition keys, query text, conflict
// mapping) stay in this package.
package storage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

// ErrDuplicate means a document with the same id already exists.
var ErrDuplicate = errors.New("duplicate id")

// Row is the slice of a stored event that the summary reads back. Every
// feature's events carry custom and timestamp, whatever custom holds.
type Row struct {
	Custom    map[string]any `json:"custom"`
	Timestamp string         `json:"timestamp"`
}

// Store reads and writes events.
type Store interface {
	// Create stores one event document in the featureName partition. It
	// returns ErrDuplicate when the id is taken.
	Create(ctx context.Context, featureName string, doc []byte) error
	// EachRow calls fn for each event of feature with timestamp >= since,
	// oldest first. It stops at the first error fn returns.
	EachRow(ctx context.Context, feature, since string, fn func(Row) error) error
}

// Cosmos is the Store backed by one Cosmos DB container.
type Cosmos struct {
	container *azcosmos.ContainerClient
}

// NewCosmos wraps a container client.
func NewCosmos(container *azcosmos.ContainerClient) *Cosmos {
	return &Cosmos{container: container}
}

// Create uses CreateItem, not UpsertItem: eventId is server-generated and
// never resent by a well-behaved sender, so a duplicate id points at a real
// problem (a retrying client, say) that should surface instead of silently
// overwriting the original event.
func (c *Cosmos) Create(ctx context.Context, featureName string, doc []byte) error {
	_, err := c.container.CreateItem(ctx, azcosmos.NewPartitionKeyString(featureName), doc, nil)
	var respErr *azcore.ResponseError
	if errors.As(err, &respErr) && respErr.StatusCode == http.StatusConflict {
		return ErrDuplicate
	}
	return err
}

// rowsQuery orders by timestamp so the summary sees events in time order;
// its per-PR dedup relies on the first sighting of a PR being the earliest.
const rowsQuery = "SELECT c.custom, c.timestamp FROM c WHERE c.featureName = @feature AND c.timestamp >= @since ORDER BY c.timestamp ASC"

// EachRow runs a single-partition query. Rows that fail to decode are
// skipped rather than failing the whole summary.
func (c *Cosmos) EachRow(ctx context.Context, feature, since string, fn func(Row) error) error {
	pager := c.container.NewQueryItemsPager(rowsQuery, azcosmos.NewPartitionKeyString(feature), &azcosmos.QueryOptions{
		QueryParameters: []azcosmos.QueryParameter{
			{Name: "@feature", Value: feature},
			{Name: "@since", Value: since},
		},
	})
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("query events: %w", err)
		}
		for _, item := range page.Items {
			var row Row
			if err := json.Unmarshal(item, &row); err != nil {
				continue
			}
			if err := fn(row); err != nil {
				return err
			}
		}
	}
	return nil
}
