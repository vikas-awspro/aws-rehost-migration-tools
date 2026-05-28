-- =============================================================================
-- MySQL DMS user — minimum privileges for full-load + binlog-based CDC.
-- =============================================================================

DROP USER IF EXISTS 'dms_user'@'%';
CREATE USER 'dms_user'@'%' IDENTIFIED BY 'REPLACE_ME_FROM_SECRETS_MANAGER' REQUIRE SSL;

GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'dms_user'@'%';
GRANT SELECT, SHOW VIEW ON *.* TO 'dms_user'@'%';
FLUSH PRIVILEGES;

-- Verify
SELECT user, host, ssl_type FROM mysql.user WHERE user = 'dms_user';
SHOW GRANTS FOR 'dms_user'@'%';
