-- =============================================================================
-- SQL Server source preparation for DMS CDC (DMS-FR-07, TIG §B.2 step 4).
-- Enables MS-CDC at the database level and for every user table.
-- Run as sysadmin (or db_owner) against each source database in scope.
-- =============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- 1. Enable CDC at the database level.
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = DB_NAME() AND is_cdc_enabled = 1)
BEGIN
    EXEC sys.sp_cdc_enable_db;
    PRINT 'CDC enabled at database level on ' + DB_NAME();
END
ELSE
BEGIN
    PRINT 'CDC already enabled at database level on ' + DB_NAME();
END

-- 2. Enable CDC on every user table in scope.
-- The DMS user must have access to the cdc.* tables created here.
DECLARE @schema sysname, @table sysname;
DECLARE table_cursor CURSOR FAST_FORWARD FOR
    SELECT s.name, t.name
      FROM sys.tables t
      JOIN sys.schemas s ON s.schema_id = t.schema_id
     WHERE t.is_ms_shipped = 0
       AND s.name NOT IN ('cdc', 'sys');

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @schema, @table;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM cdc.change_tables ct
         WHERE ct.source_object_id = OBJECT_ID(@schema + '.' + @table)
    )
    BEGIN
        EXEC sys.sp_cdc_enable_table
             @source_schema = @schema,
             @source_name   = @table,
             @role_name     = NULL,
             @supports_net_changes = 0;
        PRINT 'CDC enabled: ' + @schema + '.' + @table;
    END
    FETCH NEXT FROM table_cursor INTO @schema, @table;
END
CLOSE table_cursor;
DEALLOCATE table_cursor;

-- 3. Verify
SELECT name AS database_name, is_cdc_enabled FROM sys.databases WHERE name = DB_NAME();
SELECT capture_instance, source_object_id, start_lsn FROM cdc.change_tables ORDER BY create_date DESC;
