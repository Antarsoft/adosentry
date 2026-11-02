use axum::{extract::{Path, State}, Json};
use uuid::Uuid;

use crate::{auth::CurrentUser, error::AppError, state::AppState, models::Product};

pub async fn get_product(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<Uuid>,
) -> Result<Json<Product>, AppError> {
    let product = sqlx::query_as::<_, Product>("SELECT id, name, price_cents FROM products WHERE id = $1 AND tenant_id = $2")
        .bind(id)
        .bind(user.tenant_id)
        .fetch_optional(&state.db)
        .await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(product))
}
