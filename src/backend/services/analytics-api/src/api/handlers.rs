//! Route handlers.

use axum::extract::{Extension, Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use sea_orm::{ColumnTrait, Condition, EntityTrait, IntoActiveModel, QueryFilter, Set, ActiveModelTrait, NotSet};
use std::sync::Arc;
use uuid::Uuid;

use super::AppState;
use crate::auth::SecurityContext;
use crate::domain::query::{PageInfo, QueryRequest, QueryResponse};
use crate::domain::view::{CreateViewRequest, TableColumn, UpdateViewRequest, View};
use crate::infra::db::entities;

// ── Health ──────────────────────────────────────────────────

pub async fn health() -> impl IntoResponse {
    Json(serde_json::json!({ "status": "healthy" }))
}

// ── Views CRUD ──────────────────────────────────────────────

pub async fn list_views(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
) -> Result<impl IntoResponse, StatusCode> {
    let views = entities::views::Entity::find()
        .filter(entities::views::Column::InsightTenantId.eq(ctx.insight_tenant_id))
        .filter(entities::views::Column::IsEnabled.eq(true))
        .all(&state.db)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "failed to list views");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let items: Vec<View> = views.into_iter().map(model_to_view).collect();

    Ok(Json(serde_json::json!({ "items": items })))
}

pub async fn get_view(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, StatusCode> {
    let view = entities::views::Entity::find_by_id(id)
        .filter(entities::views::Column::InsightTenantId.eq(ctx.insight_tenant_id))
        .one(&state.db)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "failed to get view");
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .ok_or(StatusCode::NOT_FOUND)?;

    Ok(Json(model_to_view(view)))
}

pub async fn create_view(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
    Json(req): Json<CreateViewRequest>,
) -> Result<impl IntoResponse, StatusCode> {
    let id = Uuid::now_v7();

    let model = entities::views::ActiveModel {
        id: Set(id),
        insight_tenant_id: Set(ctx.insight_tenant_id),
        name: Set(req.name),
        description: Set(req.description),
        clickhouse_table: Set(req.clickhouse_table),
        base_query: Set(req.base_query),
        is_enabled: Set(true),
        created_at: NotSet,
        updated_at: NotSet,
    };

    entities::views::Entity::insert(model)
        .exec(&state.db)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "failed to create view");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    // Re-fetch to get timestamps
    let view = entities::views::Entity::find_by_id(id)
        .one(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok((StatusCode::CREATED, Json(model_to_view(view))))
}

pub async fn update_view(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateViewRequest>,
) -> Result<impl IntoResponse, StatusCode> {
    let existing = entities::views::Entity::find_by_id(id)
        .filter(entities::views::Column::InsightTenantId.eq(ctx.insight_tenant_id))
        .one(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;

    let mut model: entities::views::ActiveModel = existing.into();

    if let Some(name) = req.name {
        model.name = Set(name);
    }
    if let Some(desc) = req.description {
        model.description = Set(Some(desc));
    }
    if let Some(table) = req.clickhouse_table {
        model.clickhouse_table = Set(table);
    }
    if let Some(query) = req.base_query {
        model.base_query = Set(query);
    }
    if let Some(enabled) = req.is_enabled {
        model.is_enabled = Set(enabled);
    }

    let updated = model.update(&state.db).await.map_err(|e| {
        tracing::error!(error = %e, "failed to update view");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    Ok(Json(model_to_view(updated)))
}

pub async fn delete_view(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, StatusCode> {
    let existing = entities::views::Entity::find_by_id(id)
        .filter(entities::views::Column::InsightTenantId.eq(ctx.insight_tenant_id))
        .one(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;

    let mut model: entities::views::ActiveModel = existing.into();
    model.is_enabled = Set(false);
    model.update(&state.db).await.map_err(|e| {
        tracing::error!(error = %e, "failed to soft-delete view");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    Ok(StatusCode::NO_CONTENT)
}

// ── Query ───────────────────────────────────────────────────

pub async fn query_view(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
    Path(id): Path<Uuid>,
    Json(req): Json<QueryRequest>,
) -> Result<impl IntoResponse, StatusCode> {
    // 1. Load view definition
    let view = entities::views::Entity::find_by_id(id)
        .filter(entities::views::Column::InsightTenantId.eq(ctx.insight_tenant_id))
        .filter(entities::views::Column::IsEnabled.eq(true))
        .one(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;

    // 2. Validate limit
    let limit = req.limit.min(200).max(1);

    // 3. Build ClickHouse query from base_query + security filters + user filters
    //
    // TODO: This is a simplified implementation. The full version should:
    // - Parse base_query to extract column names for order_by validation
    // - Resolve person_ids via Identity Resolution API
    // - Apply org-unit scope from AccessScope
    // - Apply membership time ranges
    // - Implement cursor-based pagination (decode cursor → offset)

    let mut qb = state
        .ch
        .tenant_query(&view.clickhouse_table, ctx.insight_tenant_id)
        .map_err(|e| {
            tracing::error!(error = %e, "invalid table in view");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    // Apply date filters
    if let Some(ref date_from) = req.filters.date_from {
        qb = qb.filter("metric_date >= ?", date_from.as_str()).map_err(|e| {
            tracing::warn!(error = %e, "invalid date_from filter");
            StatusCode::BAD_REQUEST
        })?;
    }
    if let Some(ref date_to) = req.filters.date_to {
        qb = qb.filter("metric_date < ?", date_to.as_str()).map_err(|e| {
            tracing::warn!(error = %e, "invalid date_to filter");
            StatusCode::BAD_REQUEST
        })?;
    }

    // Apply ordering
    if let Some(ref order_by) = req.order_by {
        let dir = if req.order_dir == "asc" { "ASC" } else { "DESC" };
        let clause = format!("{order_by} {dir}");
        qb = qb.order_by(&clause).map_err(|e| {
            tracing::warn!(error = %e, order_by = %order_by, "invalid order_by");
            StatusCode::BAD_REQUEST
        })?;
    }

    // Apply pagination (fetch limit+1 to detect has_next)
    qb = qb.limit(limit + 1);

    // TODO: Execute the query. Currently the insight-clickhouse crate's
    // fetch_all requires Row trait implementations for the result type.
    // For dynamic views (columns vary per view), we need either:
    // - A generic row type that deserializes any column set
    // - Raw query execution returning serde_json::Value rows
    //
    // For now, return the SQL for debugging.
    let sql = qb.to_sql();
    tracing::debug!(sql = %sql, view_id = %id, "executing view query");

    // Placeholder response
    let response = QueryResponse {
        items: vec![serde_json::json!({
            "_debug_sql": sql,
            "_note": "query execution not yet implemented — need dynamic row deserialization"
        })],
        page_info: PageInfo {
            has_next: false,
            cursor: None,
        },
    };

    Ok(Json(response))
}

// ── Columns ─────────────────────────────────────────────────

pub async fn list_columns(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
) -> Result<impl IntoResponse, StatusCode> {
    let columns = entities::table_columns::Entity::find()
        .filter(
            Condition::any()
                .add(entities::table_columns::Column::InsightTenantId.is_null())
                .add(entities::table_columns::Column::InsightTenantId.eq(ctx.insight_tenant_id)),
        )
        .all(&state.db)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "failed to list columns");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let items: Vec<TableColumn> = columns.into_iter().map(model_to_column).collect();

    Ok(Json(serde_json::json!({ "items": items })))
}

pub async fn list_columns_for_table(
    State(state): State<Arc<AppState>>,
    Extension(ctx): Extension<SecurityContext>,
    Path(table): Path<String>,
) -> Result<impl IntoResponse, StatusCode> {
    let columns = entities::table_columns::Entity::find()
        .filter(entities::table_columns::Column::ClickhouseTable.eq(&table))
        .filter(
            Condition::any()
                .add(entities::table_columns::Column::InsightTenantId.is_null())
                .add(entities::table_columns::Column::InsightTenantId.eq(ctx.insight_tenant_id)),
        )
        .all(&state.db)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "failed to list columns for table");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let items: Vec<TableColumn> = columns.into_iter().map(model_to_column).collect();

    Ok(Json(serde_json::json!({ "items": items })))
}

// ── Mappers ─────────────────────────────────────────────────

fn model_to_view(m: entities::views::Model) -> View {
    View {
        id: m.id,
        insight_tenant_id: m.insight_tenant_id,
        name: m.name,
        description: m.description,
        clickhouse_table: m.clickhouse_table,
        base_query: m.base_query,
        is_enabled: m.is_enabled,
        created_at: m.created_at.naive_utc(),
        updated_at: m.updated_at.naive_utc(),
    }
}

fn model_to_column(m: entities::table_columns::Model) -> TableColumn {
    TableColumn {
        id: m.id,
        insight_tenant_id: m.insight_tenant_id,
        clickhouse_table: m.clickhouse_table,
        field_name: m.field_name,
        field_description: m.field_description,
    }
}
