use clickhouse::Client;

/// Configuration for a ClickHouse connection.
#[derive(Debug, Clone)]
pub struct ChConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
}

impl ChConfig {
    #[must_use]
    pub fn http_url(&self) -> String {
        // The `clickhouse` crate drives the HTTP interface; port 8123 by default.
        // When operators pass the native port (9000) we still use the HTTP endpoint
        // derived from `host`; production deployments expose both on the same host.
        format!("http://{}:8123", self.host)
    }

    #[must_use]
    pub fn client(&self) -> Client {
        Client::default()
            .with_url(self.http_url())
            .with_user(&self.user)
            .with_password(&self.password)
            .with_database(&self.database)
            // Disable schema validation: `Client::insert()` with validation runs a pre-flight
            // `DESCRIBE TABLE` and uses `RowBinaryWithNamesAndTypes`. Our `FieldHistoryInsert`
            // struct matches the DDL column order exactly, so plain `RowBinary` is safe and
            // avoids the DESCRIBE round-trip.
            .with_validation(false)
            // Long-running cursors on multi-million-row tables hit CH's default HTTP send
            // timeouts (30s) and cause unexpected EOFs.
            .with_option("send_timeout", "3600")
            .with_option("receive_timeout", "3600")
    }
}
