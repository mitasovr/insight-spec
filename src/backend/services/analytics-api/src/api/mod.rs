//! HTTP API layer — routes and handlers.

mod handlers;

use axum::{Router, middleware};
use sea_orm::DatabaseConnection;
use std::sync::Arc;

use crate::auth;
use crate::config::AppConfig;

/// Shared application state.
#[derive(Clone)]
pub struct AppState {
    pub db: DatabaseConnection,
    pub ch: insight_clickhouse::Client,
    pub config: AppConfig,
}

/// Build the Axum router with all routes.
pub fn router(state: AppState) -> Router {
    let state = Arc::new(state);

    Router::new()
        // View CRUD
        .route("/v1/views", axum::routing::get(handlers::list_views))
        .route("/v1/views", axum::routing::post(handlers::create_view))
        .route("/v1/views/{id}", axum::routing::get(handlers::get_view))
        .route("/v1/views/{id}", axum::routing::put(handlers::update_view))
        .route("/v1/views/{id}", axum::routing::delete(handlers::delete_view))
        // Query
        .route("/v1/views/{id}/query", axum::routing::post(handlers::query_view))
        // Column catalog
        .route("/v1/columns", axum::routing::get(handlers::list_columns))
        .route("/v1/columns/{table}", axum::routing::get(handlers::list_columns_for_table))
        // Health
        .route("/health", axum::routing::get(handlers::health))
        // Auth middleware on all routes
        .layer(middleware::from_fn(auth::auth_middleware))
        .with_state(state)
}
