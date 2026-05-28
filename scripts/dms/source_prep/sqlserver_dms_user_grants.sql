-- =============================================================================
-- SQL Server DMS user — minimum privileges for full-load + MS-CDC.
-- Run as sysadmin against each source database in scope.
-- =============================================================================
USE master;
GO

CREATE LOGIN dms_user WITH PASSWORD = 'REPLACE_ME_FROM_SECRETS_MANAGER';
GO

-- Per-database mapping (repeat for every source DB).
USE RISKANALYTICS_DB;
GO
CREATE USER dms_user FOR LOGIN dms_user;
EXEC sp_addrolemember 'db_owner', 'dms_user';
-- Note: AWS DMS recommends db_owner for the MS-CDC source. For tighter
-- scoping, grant: VIEW SERVER STATE, VIEW ANY DEFINITION, plus EXEC on
-- sys.sp_repldone, sp_replcmds, sp_replshowcmds, sp_replflush.
GO

USE REPORTING_DB;
GO
CREATE USER dms_user FOR LOGIN dms_user;
EXEC sp_addrolemember 'db_owner', 'dms_user';
GO

-- Verify
SELECT name, type_desc FROM sys.server_principals WHERE name = 'dms_user';
