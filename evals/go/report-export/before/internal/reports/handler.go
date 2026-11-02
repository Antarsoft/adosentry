package reports

import (
	"database/sql"
	"encoding/json"
	"net/http"
)

type Handler struct {
	DB *sql.DB
}

func (h *Handler) Summary(w http.ResponseWriter, r *http.Request) {
	tenant := TenantFrom(r.Context())
	var total int64
	err := h.DB.QueryRowContext(r.Context(), "SELECT COALESCE(SUM(amount), 0) FROM payments WHERE tenant_id = $1", tenant).Scan(&total)
	if err != nil {
		http.Error(w, "could not load summary", http.StatusInternalServerError)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]int64{"total": total})
}
