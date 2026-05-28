#!/usr/bin/env python3
"""
Validate inventory/*.yaml against a JSON Schema.

Run by `script-checks.yml`. Exits non-zero if any inventory file fails.
Catches the most common errors (mis-typed priority, missing required keys,
illegal target_engine values) at PR time rather than mid-apply.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
INV = ROOT / "inventory"


SERVER_SCHEMA = {
    "type": "object",
    "required": ["name", "os", "target_instance_type", "priority", "target_subnet"],
    "properties": {
        "name":               {"type": "string", "pattern": r"^[a-z0-9-]{1,32}$"},
        "os":                 {"enum": ["rhel7", "rhel8", "centos7", "windows2016", "windows2019", "windows2022"]},
        "vcpu":               {"type": "integer", "minimum": 1},
        "ram_gb":             {"type": "integer", "minimum": 1},
        "storage_gb":         {"type": "integer", "minimum": 1},
        "application":        {"type": "string"},
        "priority":           {"enum": ["P1", "P2", "P3"]},
        "target_instance_type": {"type": "string"},
        "target_subnet":      {"type": "string"},
        "join_domain":        {"type": "boolean"},
        "dependencies":       {"type": "array", "items": {"type": "string"}},
    },
    "additionalProperties": False,
}

DATABASE_SCHEMA = {
    "type": "object",
    "required": ["id", "name", "source_engine", "source_host",
                 "target_engine", "migration_type", "secrets_id", "target_secret_id"],
    "properties": {
        "id":                {"type": "string", "pattern": r"^db-[a-z0-9-]+$"},
        "name":              {"type": "string"},
        "source_engine":     {"enum": ["oracle", "sqlserver", "mysql", "postgres"]},
        "source_version":    {"type": ["string", "number"]},
        "source_host":       {"type": "string"},
        "source_port":       {"type": "integer"},
        "source_sid":        {"type": "string"},
        "source_database":   {"type": "string"},
        "size_tb":           {"type": "number"},
        "size_gb":           {"type": "number"},
        "target_engine":     {"enum": ["aurora-postgresql", "aurora-mysql", "sqlserver",
                                       "rds-postgres", "rds-mysql"]},
        "target_version":    {"type": "string"},
        "migration_type":    {"enum": ["homogeneous", "heterogeneous"]},
        "sct_required":      {"type": "boolean"},
        "secrets_id":        {"type": "string"},
        "target_secret_id":  {"type": "string"},
        "lob_mode":          {"enum": ["limited", "full"]},
        "lob_max_size_kb":   {"type": "integer"},
        "cdc_method":        {"type": "string"},
        "table_mapping_schema": {"type": "string"},
    },
    "additionalProperties": False,
}

SHARE_SCHEMA = {
    "type": "object",
    "required": ["id", "name", "protocol", "source_server", "size_tb", "target_service", "verify_mode", "priority"],
    "properties": {
        "id":                  {"type": "string", "pattern": r"^fs-[a-z0-9-]+$"},
        "name":                {"type": "string"},
        "protocol":            {"enum": ["nfs", "smb"]},
        "nfs_version":         {"enum": ["NFSv3", "NFSv4", "NFSv4.0", "NFSv4.1"]},
        "smb_version":         {"type": "string"},
        "source_server":       {"type": "string"},
        "source_mount_path":   {"type": "string"},
        "source_share":        {"type": "string"},
        "source_domain":       {"type": "string"},
        "source_user_secret_id": {"type": "string"},
        "size_tb":             {"type": "number"},
        "file_count":          {"type": "integer"},
        "target_service":      {"enum": ["efs", "fsx_windows", "fsx_ontap", "s3"]},
        "target_mount_path":   {"type": "string"},
        "target_fsx_share":    {"type": "string"},
        "target_fsx_throughput_mbps":      {"type": "integer"},
        "target_efs_throughput_mode":      {"enum": ["bursting", "provisioned", "elastic"]},
        "target_efs_performance_mode":     {"enum": ["generalPurpose", "maxIO"]},
        "verify_mode":         {"enum": ["BEST_EFFORT", "ONLY_FILES_TRANSFERRED", "NONE"]},
        "schedule_cron":       {"type": "string"},
        "bandwidth_limit_mbps_business_hours": {"type": "integer"},
        "posix_permissions":   {"enum": ["PRESERVE", "NONE"]},
        "smb_acls":            {"enum": ["BEST_EFFORT", "NONE"]},
        "priority":            {"enum": ["P1", "P2", "P3"]},
    },
    "additionalProperties": False,
}


def validate_file(path: Path, schema: dict, list_key: str) -> int:
    data = yaml.safe_load(path.read_text())
    items = data.get(list_key, [])
    validator = Draft202012Validator(schema)
    errors = 0
    for item in items:
        for err in validator.iter_errors(item):
            print(f"{path.name}: {item.get('name', item.get('id', '?'))}: {err.message}")
            errors += 1
    print(f"{path.name}: validated {len(items)} entries, {errors} errors")
    return errors


def main() -> int:
    total = 0
    total += validate_file(INV / "servers.yaml",     SERVER_SCHEMA,   "servers")
    total += validate_file(INV / "databases.yaml",   DATABASE_SCHEMA, "databases")
    total += validate_file(INV / "file_shares.yaml", SHARE_SCHEMA,    "file_shares")
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
