//! Create `table_columns` table.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .create_table(
                Table::create()
                    .table(TableColumns::Table)
                    .if_not_exists()
                    .col(
                        ColumnDef::new(TableColumns::Id)
                            .uuid()
                            .not_null()
                            .primary_key(),
                    )
                    .col(ColumnDef::new(TableColumns::InsightTenantId).uuid())
                    .col(
                        ColumnDef::new(TableColumns::ClickhouseTable)
                            .string_len(255)
                            .not_null(),
                    )
                    .col(
                        ColumnDef::new(TableColumns::FieldName)
                            .string_len(255)
                            .not_null(),
                    )
                    .col(ColumnDef::new(TableColumns::FieldDescription).text())
                    .col(
                        ColumnDef::new(TableColumns::CreatedAt)
                            .timestamp_with_time_zone()
                            .not_null()
                            .default(Expr::current_timestamp()),
                    )
                    .col(
                        ColumnDef::new(TableColumns::UpdatedAt)
                            .timestamp_with_time_zone()
                            .not_null()
                            .default(Expr::current_timestamp()),
                    )
                    .to_owned(),
            )
            .await?;

        // Unique constraint: one column per table per tenant (NULL tenant = shared)
        manager
            .create_index(
                Index::create()
                    .name("uq_tenant_table_field")
                    .table(TableColumns::Table)
                    .col(TableColumns::InsightTenantId)
                    .col(TableColumns::ClickhouseTable)
                    .col(TableColumns::FieldName)
                    .unique()
                    .to_owned(),
            )
            .await?;

        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .drop_table(Table::drop().table(TableColumns::Table).to_owned())
            .await
    }
}

#[derive(DeriveIden)]
enum TableColumns {
    Table,
    Id,
    InsightTenantId,
    ClickhouseTable,
    FieldName,
    FieldDescription,
    CreatedAt,
    UpdatedAt,
}
