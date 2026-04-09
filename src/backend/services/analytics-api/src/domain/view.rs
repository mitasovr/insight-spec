//! View domain model.

use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A view definition — an admin-configured SQL query against `ClickHouse`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct View {
    pub id: Uuid,
    pub insight_tenant_id: Uuid,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub clickhouse_table: String,
    pub base_query: String,
    pub is_enabled: bool,
    pub created_at: NaiveDateTime,
    pub updated_at: NaiveDateTime,
}

/// Request to create a new view.
#[derive(Debug, Deserialize)]
pub struct CreateViewRequest {
    pub name: String,
    pub description: Option<String>,
    pub clickhouse_table: String,
    pub base_query: String,
}

/// Request to update a view.
#[derive(Debug, Deserialize)]
pub struct UpdateViewRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub clickhouse_table: Option<String>,
    pub base_query: Option<String>,
    pub is_enabled: Option<bool>,
}

/// A column in the `ClickHouse` schema catalog.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TableColumn {
    pub id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub insight_tenant_id: Option<Uuid>,
    pub clickhouse_table: String,
    pub field_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field_description: Option<String>,
}
