//! Create `views` table.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .create_table(
                Table::create()
                    .table(Views::Table)
                    .if_not_exists()
                    .col(ColumnDef::new(Views::Id).uuid().not_null().primary_key())
                    .col(ColumnDef::new(Views::InsightTenantId).uuid().not_null())
                    .col(
                        ColumnDef::new(Views::Name)
                            .string_len(255)
                            .not_null(),
                    )
                    .col(ColumnDef::new(Views::Description).text())
                    .col(
                        ColumnDef::new(Views::ClickhouseTable)
                            .string_len(255)
                            .not_null(),
                    )
                    .col(ColumnDef::new(Views::BaseQuery).text().not_null())
                    .col(
                        ColumnDef::new(Views::IsEnabled)
                            .boolean()
                            .not_null()
                            .default(true),
                    )
                    .col(
                        ColumnDef::new(Views::CreatedAt)
                            .timestamp_with_time_zone()
                            .not_null()
                            .default(Expr::current_timestamp()),
                    )
                    .col(
                        ColumnDef::new(Views::UpdatedAt)
                            .timestamp_with_time_zone()
                            .not_null()
                            .default(Expr::current_timestamp()),
                    )
                    .to_owned(),
            )
            .await?;

        // Index for listing views by tenant
        manager
            .create_index(
                Index::create()
                    .name("idx_views_tenant_enabled")
                    .table(Views::Table)
                    .col(Views::InsightTenantId)
                    .col(Views::IsEnabled)
                    .to_owned(),
            )
            .await?;

        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .drop_table(Table::drop().table(Views::Table).to_owned())
            .await
    }
}

#[derive(DeriveIden)]
enum Views {
    Table,
    Id,
    InsightTenantId,
    Name,
    Description,
    ClickhouseTable,
    BaseQuery,
    IsEnabled,
    CreatedAt,
    UpdatedAt,
}
