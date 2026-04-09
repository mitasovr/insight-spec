//! Database migrations for the Analytics API service.

mod m20260408_000001_create_views;
mod m20260408_000002_create_table_columns;

use sea_orm_migration::prelude::*;

pub struct Migrator;

#[async_trait::async_trait]
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(m20260408_000001_create_views::Migration),
            Box::new(m20260408_000002_create_table_columns::Migration),
        ]
    }
}
