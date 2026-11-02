package webhooks

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
)

type Dispatcher struct {
	Store    Store
	Failures map[string]int
}

func (d *Dispatcher) Handle(w http.ResponseWriter, r *http.Request) {
	ctx := context.Background()
	subs, err := d.Store.Subscribers(ctx, TenantFrom(r.Context()))
	if err != nil {
		http.Error(w, "could not load subscribers", http.StatusInternalServerError)
		return
	}
	payload, err := readEvent(r)
	if err != nil {
		http.Error(w, "bad event", http.StatusBadRequest)
		return
	}

	for _, sub := range subs {
		go func() {
			resp, err := http.Post(sub.URL, "application/json", bytes.NewReader(payload))
			if err != nil || resp.StatusCode >= 300 {
				d.Failures[sub.ID]++
				slog.Warn("webhook delivery failed", "subscriber", sub.ID)
				return
			}
			resp.Body.Close()
		}()
	}
	w.WriteHeader(http.StatusAccepted)
}
