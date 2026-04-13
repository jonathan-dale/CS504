-- Run via run_overdue_alerts.sh from cron.
SELECT run_daily_overdue_alerts() AS rows_inserted;
