//! Identity Resolution API client.
//!
//! Resolves Insight person IDs to source-specific aliases.
//! Used when querying Silver tables that don't have a unified `person_id`.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A resolved alias from Identity Resolution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersonAlias {
    pub alias_type: String,
    pub alias_value: String,
    pub insight_source_id: Uuid,
}

#[derive(Deserialize)]
struct AliasResponse {
    aliases: Vec<PersonAlias>,
}

/// Identity Resolution API client.
pub struct IdentityResolutionClient {
    base_url: String,
    http: reqwest::Client,
}

impl IdentityResolutionClient {
    #[must_use]
    pub fn new(base_url: &str) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_owned(),
            http: reqwest::Client::new(),
        }
    }

    /// Resolve a person ID to all known aliases.
    ///
    /// Calls `GET {base_url}/v1/persons/{person_id}/aliases` with the Bearer token
    /// forwarded from the original request.
    ///
    /// # Errors
    ///
    /// Returns error if the Identity Resolution API is unreachable or returns an error.
    pub async fn resolve_aliases(
        &self,
        person_id: Uuid,
        bearer_token: &str,
    ) -> anyhow::Result<Vec<PersonAlias>> {
        let url = format!("{}/v1/persons/{person_id}/aliases", self.base_url);

        let resp = self
            .http
            .get(&url)
            .header("Authorization", format!("Bearer {bearer_token}"))
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            tracing::warn!(
                person_id = %person_id,
                status = %status,
                body = %body,
                "identity resolution request failed"
            );
            anyhow::bail!("identity resolution returned {status}: {body}");
        }

        let data: AliasResponse = resp.json().await?;
        Ok(data.aliases)
    }
}
