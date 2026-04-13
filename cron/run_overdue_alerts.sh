#!/usr/bin/env sh
# Daily overdue batch. Requires Stage_3.sql (view, overdue_alert_log, overdue_occurrences, run_daily_overdue_alerts).
#
# Crontab (every day at 00:05):
#   5 0 * * * PGDATABASE=your_db PGUSER=your_user /full/path/to/cron/run_overdue_alerts.sh >>/var/log/overdue_alerts.log 2>&1
#
# Connection: standard libpq env vars PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSFILE / .pgpass

set -eu
cd "$(dirname "$0")"
exec psql -v ON_ERROR_STOP=1 -f overdue_alerts_daily.sql
