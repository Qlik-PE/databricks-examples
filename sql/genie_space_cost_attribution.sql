-- Databricks consumption attributed to Genie spaces
-- Requires access to system.billing and system.query schemas
--
-- Parameters (Databricks SQL named parameter markers):
--   :start_date    DATE    first usage date to include, e.g. current_date() - INTERVAL 1 DAY
--   :warehouse_id  STRING  SQL warehouse used exclusively by the Genie spaces
--   :account_id    STRING  Databricks account ID
--   :workspace_id  STRING  Databricks workspace ID
--
-- Edit the genie_spaces CTE to list the Genie space IDs and display names to report on.
WITH genie_spaces AS (
  SELECT * FROM VALUES
    ('<genie_space_id_1>', '<genie_space_name_1>'),
    ('<genie_space_id_2>', '<genie_space_name_2>'),
    ('<genie_space_id_3>', '<genie_space_name_3>')
  AS t(genie_space_id, genie_space_name)
),

params AS (
  SELECT
    (SELECT collect_list(genie_space_id) FROM genie_spaces) AS genie_spaces,
    CAST(:start_date AS DATE)                               AS start_date,
    :warehouse_id                                           AS warehouse_id,
    :account_id                                             AS account_id,
    :workspace_id                                           AS workspace_id
),

-- 1. Genie space queries (warehouse exclusively used by Genie)
genie_queries AS (
  SELECT
    q.compute.warehouse_id                         AS warehouse_id,
    date_trunc('HOUR', q.start_time)               AS usage_hour,
    q.query_source.genie_space_id                  AS genie_space_id,
    coalesce(q.total_task_duration_ms, q.total_duration_ms, 0) AS work_ms,
    q.total_duration_ms,
    q.read_bytes,
    q.execution_status,
    q.query_tags
  FROM system.query.history q, params p
  WHERE q.start_time >= p.start_date
    AND q.compute.warehouse_id = p.warehouse_id
    AND q.account_id = p.account_id
    AND q.workspace_id = p.workspace_id
    AND array_contains(p.genie_spaces, q.query_source.genie_space_id)
),

genie_hour AS (
  SELECT
    genie_space_id, warehouse_id, usage_hour, query_tags,
    count(*)                                        AS queries,
    count_if(execution_status = 'FAILED')           AS failed_queries,
    sum(work_ms)                                    AS genie_work_ms,
    sum(total_duration_ms)                          AS genie_duration_ms,
    sum(read_bytes)                                 AS read_bytes
  FROM genie_queries
  GROUP BY ALL
),

hour_totals AS (
  SELECT warehouse_id, usage_hour, sum(genie_work_ms) AS total_work_ms
  FROM genie_hour
  GROUP BY ALL
),

-- 2. Warehouse cost per hour (DBUs and list price $)
wh_cost_hour AS (
  SELECT
    u.usage_metadata.warehouse_id                   AS warehouse_id,
    date_trunc('HOUR', u.usage_start_time)          AS usage_hour,
    sum(u.usage_quantity)                           AS dbus,
    sum(u.usage_quantity * lp.pricing.effective_list.default) AS list_cost_usd
  FROM system.billing.usage u
  JOIN system.billing.list_prices lp
    ON  u.sku_name   = lp.sku_name
    AND u.cloud      = lp.cloud
    AND u.usage_unit = lp.usage_unit
    AND u.usage_start_time >= lp.price_start_time
    AND (lp.price_end_time IS NULL OR u.usage_start_time < lp.price_end_time)
  CROSS JOIN params p
  WHERE u.usage_date >= p.start_date
    AND u.usage_metadata.warehouse_id IS NOT NULL
  GROUP BY ALL
),

-- 3. Allocate hourly warehouse cost to each Genie space by share of work time
allocated AS (
  SELECT
    g.*,
    g.genie_work_ms / nullif(t.total_work_ms, 0)                 AS share,
    c.dbus          * g.genie_work_ms / nullif(t.total_work_ms, 0) AS attributed_dbus,
    c.list_cost_usd * g.genie_work_ms / nullif(t.total_work_ms, 0) AS attributed_cost_usd
  FROM genie_hour g
  JOIN hour_totals t USING (warehouse_id, usage_hour)
  LEFT JOIN wh_cost_hour c USING (warehouse_id, usage_hour)
),

-- 4. Warehouse compute attributed to Genie spaces
warehouse_attributed AS (
  SELECT
    'Warehouse Compute'                         AS cost_category,
    gs.genie_space_name                         AS source_name,
    a.usage_hour,
    a.warehouse_id,
    a.query_tags,
    sum(a.queries)                              AS queries,
    sum(a.failed_queries)                       AS failed_queries,
    round(sum(a.genie_duration_ms) / 1000, 1)   AS total_duration_s,
    round(sum(a.read_bytes) / power(1024, 3), 2) AS read_gb,
    round(sum(a.attributed_dbus), 3)            AS dbus,
    round(sum(a.attributed_cost_usd), 2)        AS list_cost_usd
  FROM allocated a
  JOIN genie_spaces gs USING (genie_space_id)
  GROUP BY ALL
),

-- 5. Direct Genie LLM/AI cost per space (using agent_id = genie_space_id)
genie_llm AS (
  SELECT
    gs.genie_space_name                          AS source_name,
    u.usage_date,
    round(SUM(u.usage_quantity), 3)              AS genie_llm_dbus,
    round(SUM(
      CASE WHEN u.sku_name != 'GENIE_FREE_USAGE'
           THEN u.usage_quantity * lp.pricing.effective_list.default
           ELSE 0
      END
    ), 2)                                        AS genie_llm_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices lp
    ON  u.sku_name = lp.sku_name
    AND u.usage_end_time >= lp.price_start_time
    AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
  JOIN genie_spaces gs
    ON  u.usage_metadata.genie.agent_id = gs.genie_space_id
  CROSS JOIN params p
  WHERE u.billing_origin_product = 'GENIE'
    AND u.account_id = p.account_id
    AND u.usage_date >= p.start_date
  GROUP BY ALL
)

SELECT
  w.source_name,
  w.usage_hour,
  w.warehouse_id,
  w.query_tags,
  w.queries,
  w.failed_queries,
  w.total_duration_s,
  w.read_gb,
  w.dbus                                        AS warehouse_dbus,
  w.list_cost_usd                               AS warehouse_cost_usd,
  l.genie_llm_dbus,
  l.genie_llm_cost_usd
FROM warehouse_attributed w
LEFT JOIN genie_llm l
  ON  w.source_name = l.source_name
  AND CAST(w.usage_hour AS DATE) = l.usage_date
ORDER BY w.usage_hour, w.source_name;
