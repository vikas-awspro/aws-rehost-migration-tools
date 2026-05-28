-- =============================================================================
-- MySQL source preparation for DMS CDC (TIG §B.2 step 5).
-- These are *checks* — actual changes go into my.cnf and require server restart.
--
-- Required settings:
--   log_bin              = ON
--   binlog_format        = ROW
--   binlog_row_image     = FULL
--   server_id            > 0 (unique)
--   expire_logs_seconds  >= 86400  (24h — gives DMS time to read after lag)
-- =============================================================================

SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'binlog_row_image';
SHOW VARIABLES LIKE 'server_id';
SHOW VARIABLES LIKE 'expire_logs_seconds';
SHOW VARIABLES LIKE 'gtid_mode';

-- Current position — record at DMS task start so we can rewind if needed.
SHOW MASTER STATUS;

-- Sample my.cnf snippet (must be applied and MySQL restarted):
-- [mysqld]
-- log_bin = mysql-bin
-- binlog_format = ROW
-- binlog_row_image = FULL
-- server_id = 1
-- expire_logs_seconds = 604800
-- gtid_mode = ON
-- enforce_gtid_consistency = ON
