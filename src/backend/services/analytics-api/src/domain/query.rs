//! Query request/response models.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Query request body for `POST /v1/views/{id}/query`.
#[derive(Debug, Deserialize)]
pub struct QueryRequest {
    #[serde(default)]
    pub filters: QueryFilters,
    #[serde(default)]
    pub order_by: Option<String>,
    #[serde(default = "default_order_dir")]
    pub order_dir: String,
    #[serde(default = "default_limit")]
    pub limit: u64,
    #[serde(default)]
    pub cursor: Option<String>,
}

fn default_order_dir() -> String {
    "desc".to_owned()
}

fn default_limit() -> u64 {
    25
}

/// Available query filters.
#[derive(Debug, Default, Deserialize)]
pub struct QueryFilters {
    /// Start of date range (inclusive). ISO-8601 date.
    pub date_from: Option<String>,
    /// End of date range (exclusive). ISO-8601 date.
    pub date_to: Option<String>,
    /// Insight person IDs. Resolved to source aliases before querying `ClickHouse`.
    #[serde(default)]
    pub person_ids: Vec<Uuid>,
}

/// Query response with cursor-based pagination.
#[derive(Debug, Serialize)]
pub struct QueryResponse {
    pub items: Vec<serde_json::Value>,
    pub page_info: PageInfo,
}

/// Pagination info.
#[derive(Debug, Serialize)]
pub struct PageInfo {
    pub has_next: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}
