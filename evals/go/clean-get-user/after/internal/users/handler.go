package users

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
)

type User struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
}

type Handler struct {
	DB *sql.DB
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	user, err := h.find(r, r.PathValue("id"))
	switch {
	case errors.Is(err, sql.ErrNoRows):
		http.Error(w, "not found", http.StatusNotFound)
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "load user", "err", err)
		http.Error(w, "could not load user", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(user); err != nil {
		slog.WarnContext(r.Context(), "encode user", "err", err)
	}
}

func (h *Handler) find(r *http.Request, id string) (User, error) {
	var u User
	err := h.DB.QueryRowContext(r.Context(),
		"SELECT id, display_name FROM users WHERE id = $1 AND tenant_id = $2",
		id, TenantFrom(r.Context()),
	).Scan(&u.ID, &u.DisplayName)
	if err != nil {
		return User{}, fmt.Errorf("find user %s: %w", id, err)
	}
	return u, nil
}
