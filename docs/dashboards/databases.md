# Dashboards: Databases

Grafana folder **Databases** (`helm-charts/monitoring/monitoring-raw/dashboards/data/`). Service: CloudNativePG and its
PostgreSQL clusters. Every dashboard has a reading guide at the top, a description on each panel (with the source of the
query) and annotations for firing alerts and container restarts in `keycloak`, `dependency-track`, `cnpg-system`, plus
PostgreSQL (re)starts (`changes(cnpg_pg_postmaster_start_time[5m]) > 0`).

| Dashboard (uid) | Kind | File |
|-----------------|------|------|
| PostgreSQL / Clusters (`hl-data-postgresql`) | curated, all clusters side by side | `postgresql.json` |
| CloudNativePG / Official (`hl-data-cnpg`) | official, vendored and adapted | `cnpg.json` |

Validation: `scripts/check-dashboard.py`, 0 errors on both files.

## What runs here

- **Operator**: CloudNativePG 1.30.1 (chart cloudnative-pg 0.29.1, namespace `cnpg-system`, `fullnameOverride: cnpg`,
  Deployment/Pod `cnpg-*`). Scrape job `cnpg-system/cnpg` (PodMonitor from `monitoring.podMonitorEnabled`).
- **Clusters** (owned by the Security group's apps): `keycloak/keycloak-db` (`helm-charts/keycloak/keycloak-raw`) and
  `dependency-track/dtrack-db` (`helm-charts/dependency-track/dependency-track-raw`). PostgreSQL 18.6, **one instance
  each** (no replica, no failover), `local-path` 5Gi (not enforced: the volume is a directory on the node disk), no
  separate WAL volume, **no `spec.backup`** (no Barman Cloud plugin, no PITR). Scrape jobs `keycloak/keycloak-db` and
  `dependency-track/dtrack-db` (PodMonitor from `spec.monitoring.enablePodMonitor`, exporter on :9187).

## Metrics

Reference: <https://cloudnative-pg.io/documentation/1.30/monitoring/>; the `cnpg_pg_*` / `cnpg_backends_*` metrics are
produced by the **default monitoring queries** (ConfigMap `cnpg-default-monitoring`, from the chart's
`monitoringQueriesConfigMap`).

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| Instance manager | `cnpg_collector_up`, `cnpg_collector_postgres_version{full}`, `cnpg_collector_last_collection_error`, `cnpg_collector_collection_duration_seconds{collector}`, `cnpg_collector_collections_total`, `cnpg_last_error` | is PostgreSQL answering, is metric collection working |
| Connections | `cnpg_backends_total{datname,usename,application_name,state}`, `cnpg_backends_max_tx_duration_seconds`, `cnpg_backends_waiting_total`, `cnpg_pg_settings_setting{name="max_connections"}` | connection use vs max, oldest transaction, lock waits |
| Databases | `cnpg_pg_database_size_bytes`, `cnpg_pg_database_xid_age`, `cnpg_pg_database_mxid_age` | size and growth; wraparound risk |
| pg_stat_database | `cnpg_pg_stat_database_{xact_commit,xact_rollback,blks_hit,blks_read,tup_*,temp_bytes,temp_files,deadlocks,conflicts,blk_read_time,blk_write_time}` | throughput, cache hit ratio, temp spills, deadlocks. A series without `datname` is PostgreSQL's shared-objects row |
| WAL | `cnpg_collector_pg_wal{value=count|size|keep|min|max|…}`, `cnpg_collector_pg_wal_archive_status{value=ready|done}`, `cnpg_collector_wal_{bytes,records,fpi,buffers_full}`, `cnpg_pg_stat_archiver_*` | WAL on disk, generation rate, archiving |
| Checkpoints / bgwriter | `cnpg_pg_stat_checkpointer_*`, `cnpg_pg_stat_bgwriter_*` | requested vs timed checkpoints |
| Replication | `cnpg_pg_replication_{in_recovery,lag,is_wal_receiver_up,streaming_replicas}`, `cnpg_collector_sync_replicas`, `cnpg_collector_nodes_used` | constant here (single instance) |
| Backups | `cnpg_collector_last_available_backup_timestamp`, `cnpg_collector_last_failed_backup_timestamp`, `cnpg_collector_first_recoverability_point` | 0: no backup configured |
| Settings / misc | `cnpg_pg_settings_setting{name}`, `cnpg_pg_postmaster_start_time`, `cnpg_pg_extensions_update_available`, `cnpg_collector_fencing_on`, `cnpg_collector_manual_switchover_required`, `cnpg_collector_replica_mode`, `cnpg_collector_lo_pages` | configuration, restarts, operational flags |
| Exporter cache | `cnpg_cache_hits`, `cnpg_cache_miss`, `cnpg_last_update_timestamp` | the **exporter's own query cache** (CNPG docs), not PostgreSQL's buffer cache — do not use as a cache hit ratio |
| Operator | `controller_runtime_reconcile_*{controller=cluster|backup|pooler|scheduledbackup|plugin|…}`, `controller_runtime_webhook_*`, `workqueue_*`, `leader_election_master_status`, `rest_client_requests_total`, `certwatcher_*` | operator health. `rest_client_requests_total` shows a steady stream of `409` (Conflict/AlreadyExists) on POST/PUT; they are handled by controller retries — judge operator health by reconcile errors |

## PostgreSQL / Clusters (curated)

Variable `cluster` (from `cnpg_collector_postgres_version`, multi, default All); every query selects
`pod=~"($cluster)-[0-9]+"`. Sources: D = official CNPG dashboard, Q = default monitoring queries, S = CNPG sample alert
rules (<https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/samples/monitoring/prometheusrule.yaml>),
C = CNPG cluster chart alert rules (<https://github.com/cloudnative-pg/charts/tree/main/charts/cluster/prometheus_rules>),
P = PostgreSQL docs (monitoring-stats, routine-vacuuming, wal-configuration), K = kubernetes-mixin.

- **Is PostgreSQL OK?** Up (C offline rule), connections used % (C: 80 / 95 %), longest transaction (S: 300 s),
  XID age (S: 300 M; P: autovacuum_freeze_max_age 200 M as the yellow mark), blocked backends (Q, S), collector errors,
  uptime (D), version (D), application DB size (D), volume used = node disk (C: 70 / 90 %), WAL files waiting to archive
  (D), base backups (shows "none configured").
- **Workload**: connections by state with max_connections line (D), connections by application (Q), TPS commit/rollback
  (D), rows written/fetched (D), buffer cache hit ratio (P, derived: blks_hit / (blks_hit + blks_read)), longest
  transaction by application with the 300 s line (D, S), blocked backends + deadlocks/h (S: 10/h), temp bytes (D).
- **Storage and WAL**: DB size (D), growth over 24 h (derived: `delta(...[1d])`), WAL generated (`cnpg_collector_wal_bytes`),
  WAL on disk (D), WAL archiving `.ready` + failures (D, S), checkpoints requested vs timed (D, P).
- **Metrics collector and operator**: collection duration (D), operator reconcile errors (D), operator ready/scraped.
- **Resources**: postgres container memory vs limit, CPU (K, D).

Application databases only (`datname!~"template.*|postgres|"`) in the per-database panels; the official dashboard
uses `datname=""` (shared-objects row) for its tuple/block/deadlock panels, which hides per-database activity.
EMPTY at validation: *Longest transaction by application* (filtered `> 0`, no open transaction at that moment).

## CloudNativePG / Official (vendored)

Source: <https://github.com/cloudnative-pg/grafana-dashboards/blob/7dd1bc255b5202530e1bae7b858a3bb41a2028c7/charts/cluster/grafana-dashboard.json>
(main, 2026-07-23). Why vendored instead of the chart's ConfigMap (`monitoring.grafanaDashboard`, which supports a
`grafana_folder` annotation): the chart bundles the older `cluster-v0.0.5` copy, while main fixes `$__interval` →
`$__rate_interval`, maintenance_work_mem units and the idle-database WAL false positive; and the operator panels needed a
fix. The chart's dashboard is now off (`grafanaDashboard.create: false`), so Argo CD prunes ConfigMap
`monitoring/cnpg-grafana-dashboard` (it was in folder General).

Changes: operator Pod regex `cloudnative-pg.+|cnpg-controller-manager.+` extended with `cnpg-[a-z0-9]+-[a-z0-9]+` (our
`fullnameOverride: cnpg`; upstream showed 0 ready operator Pods); removed panels that cannot have data here (Write/Flush/
Replay lag of standbys, Tablespaces gauge) and the `-wal`/`-tbs` targets of multi-target volume panels; fixed datasource
(the `DS_PROMETHEUS` variable is gone); annotations; reading guide; descriptions for panels without one; uid
`hl-data-cnpg` (was `cloudnative-pg`). Expected neutral/empty: replication status and lag (no standbys), *Last Base
Backup*, *First Recoverability Point*, WAL archive age (no backups). EMPTY at validation: the combined replication-lag
health cell (no `cnpg_pg_stat_replication_*` without standbys) and *First Recoverability Point*.

## Alerts added

`helm-charts/cloudnative-pg/cloudnative-pg-raw/values.yaml.gotmpl` (new release `cloudnative-pg-raw`, bedag/raw 2.0.2):
PrometheusRule `cnpg-system/cloudnative-pg`, for every cluster: `CNPGInstanceDown` (collector up = 0, 5 m, critical),
`CNPGHighConnections` (> 80 %, C), `CNPGLongRunningTransaction` (> 300 s, S), `CNPGDatabaseXidAge` (> 300 M, S),
`CNPGDeadlocks` (> 10/h, S), `CNPGWalArchivingFailing` (S `LastFailedArchiveTime`), `CNPGMetricsCollectionFailing`
(collection error for 15 m; derived from the documented metric). Disk space is covered by the node alerts of
kube-prometheus-stack (`NodeFilesystemSpaceFillingUp`): `local-path` volumes are the node filesystem.

## Gaps and recommendations (need the owner / the Security group)

- **No database backups beyond Velero.** Velero copies PGDATA file by file from a running PostgreSQL (Kopia FSB, no
  pre-backup hook): such a copy is not guaranteed consistent. Recommended in the Cluster objects (owned by Security):
  CNPG backups to R2 with the Barman Cloud plugin (`spec.plugins` + `ObjectStore`) and a `ScheduledBackup`, or at
  least a Velero pre-backup hook (`CHECKPOINT`, or `pg_backup_start/stop`). The *Base backups* / *Last archived WAL* /
  *First Recoverability Point* panels and `CNPGWalArchivingFailing` become meaningful then.
- **Single instance**: no failover; a Pod restart is downtime for Keycloak / Dependency-Track. `instances: 2` would
  light up the replication panels (on one node it only protects against Pod/process failures).
- **`cnpg_collector_pg_wal{value=volume_*}` are NaN** (no separate WAL volume) — expected.
- **Per-cluster alert labels**: the alerts use `namespace`/`pod`; if Alertmanager routing needs the cluster name,
  `cnpg_collector_postgres_version{cluster}` can be joined in.
