-- =============================================================================
-- Oracle DMS user — least-privilege grants for full-load + CDC.
-- Run as SYSDBA after enabling supplemental logging. Replace the password
-- before running, and store it in Secrets Manager (see TRD §6.3).
-- =============================================================================
SET ECHO ON
WHENEVER SQLERROR EXIT FAILURE

DECLARE v_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_exists FROM dba_users WHERE username = 'DMS_USER';
    IF v_exists > 0 THEN EXECUTE IMMEDIATE 'DROP USER dms_user CASCADE'; END IF;
END;
/

CREATE USER dms_user IDENTIFIED BY "REPLACE_ME_FROM_SECRETS_MANAGER";

GRANT CREATE SESSION          TO dms_user;
GRANT SELECT ANY TABLE        TO dms_user;
GRANT SELECT ANY TRANSACTION  TO dms_user;

GRANT SELECT ON V_$ARCHIVED_LOG   TO dms_user;
GRANT SELECT ON V_$LOG            TO dms_user;
GRANT SELECT ON V_$LOGFILE        TO dms_user;
GRANT SELECT ON V_$DATABASE       TO dms_user;
GRANT SELECT ON V_$THREAD         TO dms_user;
GRANT SELECT ON V_$PARAMETER      TO dms_user;
GRANT SELECT ON V_$NLS_PARAMETERS TO dms_user;
GRANT SELECT ON V_$TIMEZONE_NAMES TO dms_user;
GRANT SELECT ON V_$TRANSACTION    TO dms_user;
GRANT SELECT ON ALL_INDEXES       TO dms_user;
GRANT SELECT ON ALL_OBJECTS       TO dms_user;
GRANT SELECT ON ALL_TABLES        TO dms_user;
GRANT SELECT ON ALL_USERS         TO dms_user;
GRANT SELECT ON ALL_CATALOG       TO dms_user;
GRANT SELECT ON ALL_CONSTRAINTS   TO dms_user;
GRANT SELECT ON ALL_CONS_COLUMNS  TO dms_user;
GRANT SELECT ON ALL_TAB_COLS      TO dms_user;
GRANT SELECT ON ALL_IND_COLUMNS   TO dms_user;
GRANT SELECT ON ALL_LOG_GROUPS    TO dms_user;

GRANT LOGMINING                   TO dms_user;
GRANT EXECUTE ON DBMS_LOGMNR      TO dms_user;
GRANT EXECUTE ON DBMS_LOGMNR_D    TO dms_user;

-- Verify
SELECT username, account_status FROM dba_users WHERE username = 'DMS_USER';
