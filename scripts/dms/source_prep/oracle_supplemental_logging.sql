-- =============================================================================
-- Oracle source preparation for DMS CDC (DMS-FR-06, TIG §B.2 step 3).
-- Run as SYSDBA against the source instance BEFORE starting the DMS task.
-- =============================================================================
SET ECHO ON
WHENEVER SQLERROR EXIT FAILURE

-- Database-level minimum supplemental logging — required by DMS.
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

-- All-columns supplemental logging — required for UPDATE/DELETE CDC.
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- The database must be in ARCHIVELOG mode for DMS Binary Reader / LogMiner.
-- If not already in ARCHIVELOG, uncomment the block below (requires a brief
-- shutdown — schedule during a maintenance window).
--   SHUTDOWN IMMEDIATE;
--   STARTUP MOUNT;
--   ALTER DATABASE ARCHIVELOG;
--   ALTER DATABASE OPEN;

-- Verify.
SELECT log_mode,
       supplemental_log_data_min,
       supplemental_log_data_all
  FROM v$database;
-- Expected: ARCHIVELOG | YES | YES
