# databricks-examples

Examples of using Databricks with Qlik Cloud.

| Folder | What it is |
|---|---|
| [`finops/`](finops/) | Databricks FOCUS Cost & Usage: a Qlik Cloud app that analyses Databricks spend from Unity Catalog system tables mapped to FOCUS 1.4. |
| [`sql/`](sql/) | Standalone Databricks SQL queries over Unity Catalog system tables. |

## SQL queries

### [`genie_space_cost_attribution.sql`](sql/genie_space_cost_attribution.sql)

Attributes Databricks consumption to Genie spaces, per hour:

- **Warehouse compute**: hourly SQL warehouse DBUs and list cost from `system.billing.usage`, split across Genie spaces by each space's share of query work time in `system.query.history`. This assumes the warehouse serves only Genie.
- **Genie LLM cost**: daily Genie DBUs and list cost per space (`billing_origin_product = 'GENIE'`). `GENIE_FREE_USAGE` is counted as $0.

Requires access to the `system.billing` and `system.query` schemas.

Parameters (named parameter markers, filled in by the Databricks SQL editor or a notebook):

| Parameter | Type | Description |
|---|---|---|
| `:start_date` | DATE | First usage date to include |
| `:warehouse_id` | STRING | SQL warehouse used by the Genie spaces |
| `:account_id` | STRING | Databricks account ID |
| `:workspace_id` | STRING | Databricks workspace ID |

Before running, replace the `<genie_space_id_n>` / `<genie_space_name_n>` rows in the `genie_spaces` CTE with your Genie space IDs and display names.
