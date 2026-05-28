{
  "widgets": [
    {
      "type": "text", "x": 0, "y": 0, "width": 24, "height": 1,
      "properties": { "markdown": "# Migration Programme — ${environment}\nMGN · DMS · DataSync" }
    },
    {
      "type": "metric", "x": 0, "y": 1, "width": 12, "height": 6,
      "properties": {
        "title": "MGN — Replication lag (seconds)",
        "region": "${region}", "view": "timeSeries", "stat": "Average", "period": 300,
        "metrics": [
          [ { "expression": "SEARCH('{AWS/MGN,SourceServerID} MetricName=\"ReplicationLag\"', 'Average', 300)", "id": "mgn_lag" } ]
        ],
        "annotations": { "horizontal": [{ "label": "60s threshold", "value": 60 }] }
      }
    },
    {
      "type": "metric", "x": 12, "y": 1, "width": 12, "height": 6,
      "properties": {
        "title": "DMS — CDC target latency (seconds)",
        "region": "${region}", "view": "timeSeries", "stat": "Average", "period": 300,
        "metrics": [
          [ { "expression": "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} MetricName=\"CDCLatencyTarget\" ReplicationInstanceIdentifier=\"${dms_replication_instance_id}\"', 'Average', 300)", "id": "dms_lag" } ]
        ],
        "annotations": { "horizontal": [{ "label": "30s SLA", "value": 30 }] }
      }
    },
    {
      "type": "metric", "x": 0, "y": 7, "width": 12, "height": 6,
      "properties": {
        "title": "DMS — Full load throughput (rows/s)",
        "region": "${region}", "view": "timeSeries", "stat": "Average", "period": 300,
        "metrics": [
          [ { "expression": "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} MetricName=\"FullLoadThroughputRowsSource\" ReplicationInstanceIdentifier=\"${dms_replication_instance_id}\"', 'Sum', 300)", "id": "rows_src" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 12, "y": 7, "width": 12, "height": 6,
      "properties": {
        "title": "DMS — Validation pending + suspended + failed",
        "region": "${region}", "view": "timeSeries", "stat": "Average", "period": 300,
        "metrics": [
          [ { "expression": "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} MetricName=\"ValidationPendingRecords\" ReplicationInstanceIdentifier=\"${dms_replication_instance_id}\"', 'Average', 300)", "id": "v_pending" } ],
          [ { "expression": "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} MetricName=\"ValidationSuspendedRecords\" ReplicationInstanceIdentifier=\"${dms_replication_instance_id}\"', 'Average', 300)", "id": "v_susp" } ],
          [ { "expression": "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} MetricName=\"ValidationFailedRecords\" ReplicationInstanceIdentifier=\"${dms_replication_instance_id}\"', 'Average', 300)", "id": "v_fail" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 0, "y": 13, "width": 12, "height": 6,
      "properties": {
        "title": "DataSync — Bytes transferred per task",
        "region": "${region}", "view": "timeSeries", "stat": "Sum", "period": 300,
        "metrics": [
          [ { "expression": "SEARCH('{AWS/DataSync,TaskArn} MetricName=\"BytesTransferred\"', 'Sum', 300)", "id": "ds_bytes" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 12, "y": 13, "width": 12, "height": 6,
      "properties": {
        "title": "DMS — RI CPU + free storage",
        "region": "${region}", "view": "timeSeries", "stat": "Average", "period": 300,
        "metrics": [
          [ "AWS/DMS", "CPUUtilization", "ReplicationInstanceIdentifier", "${dms_replication_instance_id}", { "label": "CPU %" } ],
          [ ".",       "FreeStorageSpace", ".", ".", { "label": "Free storage", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "text", "x": 0, "y": 19, "width": 24, "height": 1,
      "properties": { "markdown": "**Alarm thresholds:** MGN lag > 60s · DMS CDC > 30s · DMS storage < 30 GB · DataSync verify failures > 0" }
    }
  ]
}
