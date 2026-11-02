package reports

import (
	"database/sql"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
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

func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	tenant := TenantFrom(r.Context())
	status := r.URL.Query().Get("status")
	query := fmt.Sprintf("SELECT id, payer, amount FROM payments WHERE tenant_id = '%s' AND status = '%s'", tenant, status)
	rows, err := h.DB.QueryContext(r.Context(), query)
	if err != nil {
		http.Error(w, "could not export", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/csv")
	out := csv.NewWriter(w)
	for rows.Next() {
		var id, payer string
		var amount int64
		if err := rows.Scan(&id, &payer, &amount); err != nil {
			return
		}
		out.Write([]string{id, payer, strconv.FormatInt(amount, 10)})
	}
	out.Flush()
}
