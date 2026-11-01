package storage

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
	"github.com/antarsoft/pullpicket/metrics/internal/cosmostest"
)

type fakeCredential struct{ scopes []string }

func (f *fakeCredential) GetToken(_ context.Context, opts policy.TokenRequestOptions) (azcore.AccessToken, error) {
	f.scopes = opts.Scopes
	return azcore.AccessToken{Token: "entra-token", ExpiresOn: time.Now().Add(time.Hour)}, nil
}

func TestEntraAuth(t *testing.T) {
	fake := cosmostest.NewTLS(t)
	cred := &fakeCredential{}
	store, err := openCosmos(
		CosmosConfig{Endpoint: fake.URL, Database: "db", Container: "events"},
		cred,
		&azcosmos.ClientOptions{ClientOptions: azcore.ClientOptions{Transport: fake.Client}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(context.Background(), DefaultTenant, "f", []byte(`{"id":"1","tenantId":"default","featureName":"f"}`)); err != nil {
		t.Fatal(err)
	}

	auth := fake.AuthHeaders()
	last, _ := url.QueryUnescape(auth[len(auth)-1])
	if last != "type=aad&ver=1.0&sig=entra-token" {
		t.Errorf("Authorization = %q, want the Entra token", last)
	}
	if len(cred.scopes) != 1 || !strings.HasSuffix(cred.scopes[0], "/.default") {
		t.Errorf("token scopes = %v", cred.scopes)
	}
}

func TestKeyAuthAndErrors(t *testing.T) {
	fake := cosmostest.New(t)
	store, err := OpenCosmos(CosmosConfig{Endpoint: fake.URL, Key: "ZHVtbXk=", Database: "db", Container: "events"})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	doc := []byte(`{"id":"1","tenantId":"t","featureName":"f","timestamp":"2026-01-01T00:00:00Z","custom":{"a":1}}`)
	if err := store.Create(ctx, "t", "f", doc); err != nil {
		t.Fatal(err)
	}
	auth := fake.AuthHeaders()
	if last, _ := url.QueryUnescape(auth[len(auth)-1]); !strings.HasPrefix(last, "type=master&") {
		t.Errorf("Authorization = %q, want a master-key signature", last)
	}
	if err := store.Create(ctx, "t", "f", doc); !errors.Is(err, ErrDuplicate) {
		t.Errorf("second create: err = %v, want ErrDuplicate", err)
	}

	var rows []Row
	if err := store.EachRow(ctx, "t", "f", "2025-01-01T00:00:00Z", func(r Row) error { rows = append(rows, r); return nil }); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Custom["a"] != float64(1) {
		t.Errorf("rows = %+v", rows)
	}
	stop := errors.New("stop")
	if err := store.EachRow(ctx, "t", "f", "2025-01-01T00:00:00Z", func(Row) error { return stop }); !errors.Is(err, stop) {
		t.Errorf("callback error not returned: %v", err)
	}

	fake.FailWith(500)
	if err := store.Create(ctx, "t", "f", []byte(`{"id":"2"}`)); err == nil || errors.Is(err, ErrDuplicate) {
		t.Errorf("create during outage: err = %v", err)
	}
	if err := store.EachRow(ctx, "t", "f", "", func(Row) error { return nil }); err == nil {
		t.Error("query during outage: no error")
	}

	if _, err := OpenCosmos(CosmosConfig{Endpoint: fake.URL, Key: "not base64!", Database: "db", Container: "events"}); err == nil {
		t.Error("invalid key accepted")
	}
}
