# API Reference

Base URL: `http://172.22.0.220:5000`

## Authentication

The API uses API keys for authentication. There are two types:

1. **Write Key** (`API_KEY_WRITE`): Required for POST endpoints (logging data)
2. **Read Key** (`API_KEY_READ`): Required for GET endpoints (querying data)

Include the key in the `X-API-Key` header:
```
X-API-Key: your-api-key-here
```

If no keys are configured, the API runs in development mode (no auth required).

## Timestamps

All endpoints accept an optional `device_time` field for accurate local timestamps:
```json
{
  "device_time": "2024-01-15T10:30:00+01:00"  // ISO 8601 format
  // OR
  "device_time": 1705312200  // Unix timestamp (seconds)
  // OR
  "device_time": 1705312200000  // Unix timestamp (milliseconds)
}
```

The server stores three timestamps:
- `created_at`: When the server received the data
- `device_time`: The timestamp from the device (if provided)
- `local_time`: Best available time (device_time if available, otherwise created_at)

## Logging Endpoints (require Write API Key)

### POST /api/log/event
Log a system event
```json
{
  "bridge_mac": "AA:BB:CC:DD:EE:FF",
  "sensor_mac": "11:22:33:44:55:66",
  "sensor_name": "Balkontür",
  "room": "Wohnzimmer",
  "category": "sensor",  // sensor|alarm|climate|system|power|config
  "event_type": "contact_opened",
  "severity": 0,  // 0=info, 1=warning, 2=error, 3=critical
  "message": "Door opened",
  "device_time": "2024-01-15T10:30:00+01:00",  // optional
  "esp_millis": 123456789  // optional
}
```

### POST /api/log/climate
Log climate readings
```json
{
  "sensor_mac": "11:22:33:44:55:66",
  "sensor_name": "Balkontür",
  "room": "Wohnzimmer",
  "temperature": 21.5,
  "humidity": 55.0,
  "pressure": 1013.25,
  "dew_point": 12.3,
  "mold_risk_score": 15,
  "contact_open": false,
  "alert_level": "ok",
  "device_time": "2024-01-15T10:30:00+01:00"  // optional
}
```

### POST /api/log/battery
Log battery status
```json
{
  "device_type": "sensor",  // sensor|bridge
  "device_mac": "11:22:33:44:55:66",
  "device_name": "Balkontür",
  "battery_level": 85,
  "battery_voltage": 4.02,
  "is_charging": false,
  "device_time": "2024-01-15T10:30:00+01:00"  // optional
}
```

### POST /api/log/alarm
Log alarm event
```json
{
  "bridge_mac": "AA:BB:CC:DD:EE:FF",
  "event_type": "triggered",  // armed|disarmed|triggered
  "alarm_mode": "away",
  "trigger_sensor": "11:22:33:44:55:66",
  "trigger_name": "Balkontür",
  "message": "Alarm triggered by Balkontür",
  "device_time": "2024-01-15T10:30:00+01:00"  // optional
}
```

### POST /api/log/state
Log bridge/alarm state snapshot for auditing
```json
{
  "bridge_mac": "AA:BB:CC:DD:EE:FF",
  "alarm_mode": 3,
  "alarm_mode_name": "disarmed",
  "is_armed": false,
  "in_exit_delay": false,
  "in_entry_delay": false,
  "sensors_online": 3,
  "sensors_total": 4,
  "bridge_battery": 85,
  "uptime_seconds": 86400
}
```

### POST /api/log/metrics
Log system health metrics
```json
{
  "bridge_mac": "AA:BB:CC:DD:EE:FF",
  "free_heap": 150000,
  "min_free_heap": 120000,
  "wifi_rssi": -55,
  "uptime_seconds": 86400,
  "sensors_online": 3,
  "sensors_total": 4,
  "device_time": "2024-01-15T10:30:00+01:00"  // optional
}
```

### POST /api/log/sensor-state
Update sensor current state
```json
{
  "bridge_mac": "AA:BB:CC:DD:EE:FF",
  "sensor_mac": "11:22:33:44:55:66",
  "name": "Balkontür",
  "room": "Wohnzimmer",
  "is_online": true,
  "temperature": 21.5,
  "humidity": 55.0,
  "battery_level": 85
}
```

## Query Endpoints (require Read API Key)

### GET /api/events
Query events with filters
```
?limit=100&offset=0&sensor=sensor_name&room=room&category=sensor&severity=0&from=2025-12-01&to=2025-12-31
```

Response includes `local_time` for accurate timestamps.

### GET /api/sensors
Get all sensors with current state

### GET /api/sensors/{mac}
Get single sensor with history

### GET /api/climate/{mac}
Get climate history
```
?hours=24
```

### GET /api/battery/{mac}
Get battery history
```
?days=7
```

### GET /api/alarms
Get alarm history

### GET /api/stats/daily
Get daily statistics
```
?days=7
```

### GET /api/export/events
Export events as CSV
```
?from=2025-12-01&to=2025-12-31
```

## Dashboard Endpoints (require Read API Key)

### GET /api/dashboard/summary
Quick system overview
```json
{
  "sensors_online": 3,
  "sensors_total": 4,
  "events_24h": 150,
  "errors_24h": 0,
  "current_alarm_mode": "disarmed",
  "last_event_time": "2024-01-15T10:30:00+01:00",
  "avg_temp_1h": 21.5,
  "avg_humidity_1h": 55.0
}
```

### GET /api/dashboard/recent-activity
Recent activity feed
```
?limit=50
```

### GET /api/dashboard/climate-current
Current climate readings for all sensors

## Public Endpoints (no auth required)

### GET /api/health
Health check
```json
{
  "status": "healthy",
  "database": "connected",
  "timezone": "Europe/Berlin",
  "total_events": 1500,
  "total_sensors": 4,
  "sensors_online": 3,
  "server_time": "2024-01-15T10:30:00+01:00"
}
```

### GET /api/server/time
Current server time (useful for device sync)
```json
{
  "iso": "2024-01-15T10:30:00+01:00",
  "unix": 1705312200,
  "timezone": "Europe/Berlin"
}

### GET /api/health
Health check endpoint

## Testing

```bash
# Health check (no auth)
curl -X GET http://172.22.0.220:5000/api/health

# Get server time (no auth)
curl -X GET http://172.22.0.220:5000/api/server/time

# Log an event (requires write key)
curl -X POST http://172.22.0.220:5000/api/log/event \
  -H "X-API-Key: YOUR_WRITE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "bridge_mac": "AA:BB:CC:DD:EE:FF",
    "sensor_name": "Test Sensor",
    "category": "sensor",
    "event_type": "contact_opened",
    "severity": 0,
    "message": "Test",
    "device_time": "'$(date -Iseconds)'"
  }'

# Get events (requires read key)
curl -X GET "http://172.22.0.220:5000/api/events?limit=10" \
  -H "X-API-Key: YOUR_READ_KEY"

# Dashboard summary (requires read key)
curl -X GET http://172.22.0.220:5000/api/dashboard/summary \
  -H "X-API-Key: YOUR_READ_KEY"
```

## Response Codes

| Code | Description |
|------|-------------|
| 200 | Success |
| 201 | Created (for POST requests) |
| 400 | Bad Request (missing required fields) |
| 401 | Unauthorized (invalid or missing API key) |
| 404 | Not Found |
| 500 | Server Error |

## Rate Limiting

If rate limiting is enabled (via `RATE_LIMIT_ENABLED=true`), requests are limited to `RATE_LIMIT_PER_MINUTE` per IP address.

## Database Access (for Dashboards)

For direct database access (e.g., Grafana), use the read-only dashboard user:

- User: `climax_dashboard`
- Password: (from `DB_DASHBOARD_PASSWORD` in .env)
- Database: `climax`

Useful views for dashboards:
- `v_sensor_current_state` - Current state of all sensors
- `v_recent_events` - Last 1000 events
- `v_daily_climate` - Daily climate aggregates
- `v_alarm_history` - Alarm events
- `v_battery_trends` - Battery levels over time
- `v_system_health` - System metrics
- `v_dashboard_summary` - Quick overview stats
