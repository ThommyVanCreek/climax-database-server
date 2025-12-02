-- ═══════════════════════════════════════════════════════════════════════════
-- ClimaX Security System - Complete Audit Database Schema
-- Version 3.1 - Full History Tracking with Local Timestamps & Dashboard Access
-- ═══════════════════════════════════════════════════════════════════════════

-- Create database (run as superuser)
-- CREATE DATABASE climax_security;

-- ═══════════════════════════════════════════════════════════════════════════
-- Schema Configuration
-- ═══════════════════════════════════════════════════════════════════════════

-- Create dedicated schema for ClimaX (NOT using public!)
CREATE SCHEMA IF NOT EXISTS climax AUTHORIZATION climax;

-- Set search path to use ONLY climax schema
SET search_path TO climax;

-- Set default search_path for the climax user and database
ALTER USER climax SET search_path TO climax;
ALTER DATABASE climax SET search_path TO climax;

-- ═══════════════════════════════════════════════════════════════════════════
-- Timezone Configuration
-- ═══════════════════════════════════════════════════════════════════════════

-- Set default timezone and search path for the database
ALTER DATABASE climax SET timezone TO 'Europe/Berlin';
ALTER DATABASE climax SET search_path TO climax;

-- ═══════════════════════════════════════════════════════════════════════════
-- Security: Create Dashboard Read-Only User
-- ═══════════════════════════════════════════════════════════════════════════

-- Create read-only dashboard user (replace password!)
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'climax_dashboard') THEN
        CREATE ROLE climax_dashboard WITH LOGIN PASSWORD 'CHANGE_THIS_DASHBOARD_PASSWORD';
    END IF;
END $$;

-- Grant connect permission
GRANT CONNECT ON DATABASE climax TO climax_dashboard;

-- Grant schema usage
GRANT USAGE ON SCHEMA climax TO climax_dashboard;

-- ═══════════════════════════════════════════════════════════════════════════
-- ENUM Types (in climax schema)
-- ═══════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
    CREATE TYPE climax.event_category AS ENUM (
        'sensor',           -- Sensor-related events
        'alarm',            -- Alarm system events
        'climate',          -- Climate/environmental events
        'system',           -- Bridge system events
        'communication',    -- ESP-NOW/Network events
        'power',            -- Battery/Power events
        'config'            -- Configuration changes
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE climax.event_type AS ENUM (
        -- Sensor Events
        'contact_opened',
        'contact_closed',
        'sensor_online',
        'sensor_offline',
        'sensor_timeout',
        'sensor_reconnect',
        'sensor_data_received',
        
        -- Alarm Events
        'alarm_armed_stay',
        'alarm_armed_away',
        'alarm_armed_night',
        'alarm_disarmed',
        'alarm_triggered',
        'alarm_silenced',
        'entry_delay_started',
        'entry_delay_ended',
        'exit_delay_started',
        'exit_delay_completed',
        'tamper_detected',
        
        -- Bypass Events
        'bypass_enabled',
        'bypass_disabled',
        'night_bypass_enabled',
        'night_bypass_disabled',
        'night_bypass_auto_disabled',
        
        -- Climate Events
        'climate_reading',
        'climate_alert_ok',
        'climate_alert_ventilate',
        'climate_alert_high_humidity',
        'climate_alert_mold_risk',
        'climate_alert_energy_waste',
        'window_open_warning',
        
        -- Power Events
        'battery_level_change',
        'battery_low_warning',
        'battery_critical',
        'charging_started',
        'charging_stopped',
        'usb_connected',
        'usb_disconnected',
        
        -- System Events
        'system_boot',
        'system_restart',
        'system_error',
        'state_snapshot',
        'wifi_connected',
        'wifi_disconnected',
        'homekit_paired',
        'homekit_unpaired',
        'ota_started',
        'ota_completed',
        'ota_failed',
        'ntp_synced',
        
        -- Config Events
        'sensor_added',
        'sensor_updated',
        'sensor_deleted',
        'config_changed'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE climax.alarm_mode AS ENUM (
        'disarmed',
        'stay',
        'away',
        'night',
        'triggered'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE climax.climate_alert_level AS ENUM (
        'ok',
        'ventilate',
        'high_humidity',
        'mold_risk',
        'energy_waste'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE climax.sensor_mode AS ENUM (
        'normal',
        'service',
        'charging',
        'going_offline',
        'coming_online'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Bridge Registry
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.bridges (
    id              SERIAL PRIMARY KEY,
    mac_address     VARCHAR(20) UNIQUE NOT NULL,
    hostname        VARCHAR(64),
    ip_address      VARCHAR(45),
    firmware_version VARCHAR(20),
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_boot       TIMESTAMPTZ,
    boot_count      INTEGER DEFAULT 0,
    
    -- Current state
    alarm_mode      climax.alarm_mode DEFAULT 'disarmed',
    battery_level   INTEGER,
    battery_voltage DECIMAL(4,2),
    free_heap       INTEGER,
    uptime_seconds  BIGINT
);

CREATE INDEX IF NOT EXISTS idx_bridges_mac ON bridges(mac_address);

-- ═══════════════════════════════════════════════════════════════════════════
-- Sensor Registry
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.sensors (
    id              SERIAL PRIMARY KEY,
    mac_address     VARCHAR(20) UNIQUE NOT NULL,
    bridge_mac      VARCHAR(20),
    name            VARCHAR(64),
    room            VARCHAR(64),
    is_entry_exit   BOOLEAN DEFAULT FALSE,
    is_active       BOOLEAN DEFAULT TRUE,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Current state snapshot
    contact_open    BOOLEAN,
    temperature     DECIMAL(5,2),
    humidity        DECIMAL(5,2),
    pressure        DECIMAL(7,2),
    dew_point       DECIMAL(5,2),
    battery_level   INTEGER,
    is_charging     BOOLEAN,
    is_online       BOOLEAN DEFAULT FALSE,
    operational_mode climax.sensor_mode DEFAULT 'normal',
    bypass_active   BOOLEAN DEFAULT FALSE,
    night_bypass    BOOLEAN DEFAULT FALSE,
    climate_alert   climax.climate_alert_level DEFAULT 'ok'
);

CREATE INDEX IF NOT EXISTS idx_sensors_mac ON sensors(mac_address);
CREATE INDEX IF NOT EXISTS idx_sensors_bridge ON sensors(bridge_mac);

-- ═══════════════════════════════════════════════════════════════════════════
-- Main Event Log Table (Audit Trail)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.event_log (
    id              BIGSERIAL PRIMARY KEY,
    
    -- Timestamps (all stored with timezone info)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),    -- Server receive time
    device_time     TIMESTAMPTZ,                           -- Time from ESP32 NTP (if available)
    local_time      TIMESTAMPTZ GENERATED ALWAYS AS (
                        COALESCE(device_time, created_at)
                    ) STORED,                              -- Best available local time
    esp_millis      BIGINT,                                -- ESP32 millis() for ordering
    
    -- Source
    bridge_mac      VARCHAR(20) NOT NULL,
    sensor_mac      VARCHAR(20),           -- NULL for bridge events
    sensor_name     VARCHAR(64),
    room            VARCHAR(64),
    
    -- Event Classification
    category        climax.event_category NOT NULL,
    event_type      climax.event_type NOT NULL,
    severity        INTEGER DEFAULT 0,     -- 0=info, 1=warning, 2=error, 3=critical
    
    -- Change Tracking
    old_value       TEXT,
    new_value       TEXT,
    
    -- Message
    message         TEXT,
    
    -- Full State Snapshot (optional, for important events)
    state_snapshot  JSONB,
    
    -- Additional metadata
    metadata        JSONB
);

-- Indexes for fast queries
CREATE INDEX IF NOT EXISTS idx_event_created ON event_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_event_local_time ON event_log(local_time DESC);
CREATE INDEX IF NOT EXISTS idx_event_bridge ON event_log(bridge_mac, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_event_sensor ON event_log(sensor_mac, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_event_type ON event_log(event_type, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_event_category ON event_log(category, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_event_severity ON event_log(severity, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_event_room ON event_log(room, local_time DESC);

-- Partial index for errors only
CREATE INDEX IF NOT EXISTS idx_event_errors ON event_log(local_time DESC) 
    WHERE severity >= 2;

-- ═══════════════════════════════════════════════════════════════════════════
-- Climate Data Time Series
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.climate_readings (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    device_time     TIMESTAMPTZ,           -- Time from device if available
    local_time      TIMESTAMPTZ GENERATED ALWAYS AS (
                        COALESCE(device_time, created_at)
                    ) STORED,              -- Best available local time
    
    sensor_mac      VARCHAR(20) NOT NULL,
    sensor_name     VARCHAR(64),
    room            VARCHAR(64),
    
    -- Climate values
    temperature     DECIMAL(5,2),
    humidity        DECIMAL(5,2),
    pressure        DECIMAL(7,2),
    dew_point       DECIMAL(5,2),
    
    -- Calculated values
    mold_risk_score INTEGER,
    heat_index      DECIMAL(5,2),
    
    -- Window state (for correlation)
    contact_open    BOOLEAN,
    
    -- Alert level at time of reading
    alert_level     climax.climate_alert_level
);

CREATE INDEX IF NOT EXISTS idx_climate_sensor ON climate_readings(sensor_mac, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_climate_room ON climate_readings(room, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_climate_time ON climate_readings(local_time DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- Battery History
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.battery_readings (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    device_time     TIMESTAMPTZ,           -- Time from device if available
    local_time      TIMESTAMPTZ GENERATED ALWAYS AS (
                        COALESCE(device_time, created_at)
                    ) STORED,              -- Best available local time
    
    device_type     VARCHAR(10) NOT NULL,  -- 'bridge' or 'sensor'
    device_mac      VARCHAR(20) NOT NULL,
    device_name     VARCHAR(64),
    
    battery_level   INTEGER NOT NULL,
    battery_voltage DECIMAL(4,2),
    is_charging     BOOLEAN,
    
    -- Rate of change (calculated)
    level_change    INTEGER,
    time_delta_sec  INTEGER
);

CREATE INDEX IF NOT EXISTS idx_battery_device ON battery_readings(device_mac, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_battery_time ON battery_readings(local_time DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- Alarm History
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.alarm_events (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    device_time     TIMESTAMPTZ,           -- Time from device if available
    local_time      TIMESTAMPTZ GENERATED ALWAYS AS (
                        COALESCE(device_time, created_at)
                    ) STORED,              -- Best available local time
    
    bridge_mac      VARCHAR(20) NOT NULL,
    
    event_type      VARCHAR(32) NOT NULL,
    alarm_mode      climax.alarm_mode,
    previous_mode   climax.alarm_mode,
    
    -- Trigger info (if triggered)
    trigger_sensor  VARCHAR(20),
    trigger_name    VARCHAR(64),
    trigger_room    VARCHAR(64),
    
    -- Timing
    duration_seconds INTEGER,
    
    -- Additional info
    was_silenced    BOOLEAN,
    was_entry_delay BOOLEAN,
    was_exit_delay  BOOLEAN,
    
    message         TEXT
);

CREATE INDEX IF NOT EXISTS idx_alarm_bridge ON alarm_events(bridge_mac, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_alarm_type ON alarm_events(event_type, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_alarm_time ON alarm_events(local_time DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- System Health Metrics
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.system_metrics (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    device_time     TIMESTAMPTZ,           -- Time from device if available
    local_time      TIMESTAMPTZ GENERATED ALWAYS AS (
                        COALESCE(device_time, created_at)
                    ) STORED,              -- Best available local time
    
    bridge_mac      VARCHAR(20) NOT NULL,
    
    -- Memory
    free_heap       INTEGER,
    min_free_heap   INTEGER,
    heap_fragmentation INTEGER,
    
    -- Network
    wifi_rssi       INTEGER,
    wifi_channel    INTEGER,
    
    -- Performance
    uptime_seconds  BIGINT,
    loop_time_us    INTEGER,
    
    -- Counts
    sensors_online  INTEGER,
    sensors_total   INTEGER,
    events_queued   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_metrics_bridge ON system_metrics(bridge_mac, local_time DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_time ON system_metrics(local_time DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- Functions for Auto-Updates
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_bridge_on_event()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO bridges (mac_address, last_seen)
    VALUES (NEW.bridge_mac, NOW())
    ON CONFLICT (mac_address) DO UPDATE SET
        last_seen = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_bridge ON event_log;
CREATE TRIGGER trg_update_bridge
    AFTER INSERT ON event_log
    FOR EACH ROW
    EXECUTE FUNCTION update_bridge_on_event();

CREATE OR REPLACE FUNCTION update_sensor_on_event()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.sensor_mac IS NOT NULL THEN
        INSERT INTO sensors (mac_address, bridge_mac, name, room, last_seen)
        VALUES (NEW.sensor_mac, NEW.bridge_mac, NEW.sensor_name, NEW.room, NOW())
        ON CONFLICT (mac_address) DO UPDATE SET
            name = COALESCE(EXCLUDED.name, sensors.name),
            room = COALESCE(EXCLUDED.room, sensors.room),
            bridge_mac = EXCLUDED.bridge_mac,
            last_seen = NOW();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_sensor ON event_log;
CREATE TRIGGER trg_update_sensor
    AFTER INSERT ON event_log
    FOR EACH ROW
    EXECUTE FUNCTION update_sensor_on_event();

-- ═══════════════════════════════════════════════════════════════════════════
-- Views for Easy Access
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_sensor_current_state AS
SELECT 
    s.mac_address,
    s.name,
    s.room,
    s.is_entry_exit,
    s.is_active,
    s.contact_open,
    s.temperature,
    s.humidity,
    s.pressure,
    s.dew_point,
    s.battery_level,
    s.is_charging,
    s.is_online,
    s.operational_mode,
    s.bypass_active,
    s.night_bypass,
    s.climate_alert,
    s.last_seen,
    EXTRACT(EPOCH FROM (NOW() - s.last_seen)) as seconds_since_update
FROM sensors s
ORDER BY s.room, s.name;

CREATE OR REPLACE VIEW v_recent_events AS
SELECT 
    e.id,
    e.local_time,
    e.created_at,
    e.device_time,
    e.category,
    e.event_type,
    e.severity,
    e.sensor_name,
    e.room,
    e.message,
    e.old_value,
    e.new_value
FROM event_log e
ORDER BY e.local_time DESC
LIMIT 1000;

CREATE OR REPLACE VIEW v_daily_climate AS
SELECT 
    DATE(local_time AT TIME ZONE 'Europe/Berlin') as date,
    room,
    sensor_name,
    COUNT(*) as readings,
    ROUND(AVG(temperature)::numeric, 1) as avg_temp,
    ROUND(MIN(temperature)::numeric, 1) as min_temp,
    ROUND(MAX(temperature)::numeric, 1) as max_temp,
    ROUND(AVG(humidity)::numeric, 0) as avg_humidity,
    ROUND(MIN(humidity)::numeric, 0) as min_humidity,
    ROUND(MAX(humidity)::numeric, 0) as max_humidity,
    ROUND(AVG(dew_point)::numeric, 1) as avg_dew_point
FROM climate_readings
WHERE local_time > NOW() - INTERVAL '30 days'
GROUP BY DATE(local_time AT TIME ZONE 'Europe/Berlin'), room, sensor_name
ORDER BY date DESC, room, sensor_name;

CREATE OR REPLACE VIEW v_contact_activity AS
SELECT 
    DATE(local_time AT TIME ZONE 'Europe/Berlin') as date,
    sensor_name,
    room,
    COUNT(*) FILTER (WHERE event_type = 'contact_opened') as open_count,
    COUNT(*) FILTER (WHERE event_type = 'contact_closed') as close_count
FROM event_log
WHERE event_type IN ('contact_opened', 'contact_closed')
    AND local_time > NOW() - INTERVAL '30 days'
GROUP BY DATE(local_time AT TIME ZONE 'Europe/Berlin'), sensor_name, room
ORDER BY date DESC, room, sensor_name;

CREATE OR REPLACE VIEW v_alarm_history AS
SELECT 
    a.local_time,
    a.created_at,
    a.event_type,
    a.alarm_mode,
    a.previous_mode,
    a.trigger_name,
    a.trigger_room,
    a.duration_seconds,
    a.was_silenced,
    a.message
FROM alarm_events a
ORDER BY a.local_time DESC;

CREATE OR REPLACE VIEW v_battery_trends AS
SELECT 
    device_mac,
    device_name,
    device_type,
    DATE(local_time AT TIME ZONE 'Europe/Berlin') as date,
    MIN(battery_level) as min_level,
    MAX(battery_level) as max_level,
    ROUND(AVG(battery_level)) as avg_level,
    SUM(CASE WHEN is_charging THEN 1 ELSE 0 END) as charging_readings
FROM battery_readings
WHERE local_time > NOW() - INTERVAL '30 days'
GROUP BY device_mac, device_name, device_type, DATE(local_time AT TIME ZONE 'Europe/Berlin')
ORDER BY date DESC, device_name;

CREATE OR REPLACE VIEW v_system_health AS
SELECT 
    m.local_time,
    m.created_at,
    b.hostname,
    m.free_heap,
    m.wifi_rssi,
    m.uptime_seconds,
    m.sensors_online,
    m.sensors_total,
    b.battery_level as bridge_battery,
    b.alarm_mode
FROM system_metrics m
JOIN bridges b ON b.mac_address = m.bridge_mac
ORDER BY m.local_time DESC;

-- ═══════════════════════════════════════════════════════════════════════════
-- Dashboard Summary View
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_dashboard_summary AS
SELECT 
    (SELECT COUNT(*) FROM sensors WHERE is_online = true) as sensors_online,
    (SELECT COUNT(*) FROM sensors) as sensors_total,
    (SELECT COUNT(*) FROM event_log WHERE local_time > NOW() - INTERVAL '24 hours') as events_24h,
    (SELECT COUNT(*) FROM event_log WHERE severity >= 2 AND local_time > NOW() - INTERVAL '24 hours') as errors_24h,
    (SELECT alarm_mode FROM bridges ORDER BY last_seen DESC LIMIT 1) as current_alarm_mode,
    (SELECT local_time FROM event_log ORDER BY local_time DESC LIMIT 1) as last_event_time,
    (SELECT AVG(temperature)::numeric(5,1) FROM climate_readings WHERE local_time > NOW() - INTERVAL '1 hour') as avg_temp_1h,
    (SELECT AVG(humidity)::numeric(5,1) FROM climate_readings WHERE local_time > NOW() - INTERVAL '1 hour') as avg_humidity_1h;

-- ═══════════════════════════════════════════════════════════════════════════
-- Data Retention Function
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION cleanup_old_data(days_to_keep INTEGER DEFAULT 90)
RETURNS void AS $$
BEGIN
    DELETE FROM climate_readings 
    WHERE local_time < NOW() - (days_to_keep || ' days')::INTERVAL;
    
    DELETE FROM battery_readings 
    WHERE local_time < NOW() - (days_to_keep || ' days')::INTERVAL;
    
    DELETE FROM system_metrics 
    WHERE local_time < NOW() - (days_to_keep || ' days')::INTERVAL;
    
    DELETE FROM event_log 
    WHERE local_time < NOW() - INTERVAL '180 days';
    
    DELETE FROM alarm_events 
    WHERE local_time < NOW() - INTERVAL '365 days';
END;
$$ LANGUAGE plpgsql;

-- ═══════════════════════════════════════════════════════════════════════════
-- Dashboard User Permissions (Read-Only Access)
-- ═══════════════════════════════════════════════════════════════════════════

-- Grant SELECT on all tables to dashboard user
GRANT SELECT ON ALL TABLES IN SCHEMA public TO climax_dashboard;

-- Grant SELECT on all sequences (for ID visibility)
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO climax_dashboard;

-- Ensure future tables also get SELECT permission
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO climax_dashboard;

-- Revoke any write permissions (just to be safe)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM climax_dashboard;

-- ═══════════════════════════════════════════════════════════════════════════
-- API Keys Table (for secure key storage)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.api_keys (
    id              SERIAL PRIMARY KEY,
    key_name        VARCHAR(64) NOT NULL,
    key_hash        VARCHAR(128) NOT NULL,  -- SHA-256 hash of the key
    key_type        VARCHAR(20) NOT NULL DEFAULT 'read',  -- 'read', 'write', 'admin'
    description     TEXT,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used       TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,
    allowed_ips     INET[],  -- Optional IP whitelist
    rate_limit      INTEGER DEFAULT 120  -- Requests per minute
);

CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);
CREATE INDEX IF NOT EXISTS idx_api_keys_active ON api_keys(is_active);

-- ═══════════════════════════════════════════════════════════════════════════
-- Request Log (for audit and rate limiting)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS climax.request_log (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    api_key_id      INTEGER REFERENCES api_keys(id),
    endpoint        VARCHAR(128),
    method          VARCHAR(10),
    client_ip       INET,
    response_code   INTEGER,
    response_time_ms INTEGER,
    request_size    INTEGER,
    response_size   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_request_log_time ON request_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_request_log_key ON request_log(api_key_id, created_at DESC);

-- Partition-like index for quick rate limit checks (last minute only)
CREATE INDEX IF NOT EXISTS idx_request_log_recent ON request_log(client_ip, created_at DESC)
    WHERE created_at > NOW() - INTERVAL '5 minutes';

-- ═══════════════════════════════════════════════════════════════════════════
-- Helper Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- Function to get local time in configured timezone
CREATE OR REPLACE FUNCTION get_local_time(tz TEXT DEFAULT 'Europe/Berlin')
RETURNS TIMESTAMPTZ AS $$
BEGIN
    RETURN NOW() AT TIME ZONE tz;
END;
$$ LANGUAGE plpgsql;

-- Function to convert UTC to local timezone
CREATE OR REPLACE FUNCTION to_local(ts TIMESTAMPTZ, tz TEXT DEFAULT 'Europe/Berlin')
RETURNS TIMESTAMP AS $$
BEGIN
    RETURN ts AT TIME ZONE tz;
END;
$$ LANGUAGE plpgsql;

-- Function to check rate limit for an IP
CREATE OR REPLACE FUNCTION check_rate_limit(
    check_ip INET,
    max_requests INTEGER DEFAULT 120
)
RETURNS BOOLEAN AS $$
DECLARE
    request_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO request_count
    FROM request_log
    WHERE client_ip = check_ip
        AND created_at > NOW() - INTERVAL '1 minute';
    
    RETURN request_count < max_requests;
END;
$$ LANGUAGE plpgsql;

-- ═══════════════════════════════════════════════════════════════════════════
-- Data Retention Cleanup Functions
-- These can be called via cron or pg_cron to maintain database size
-- ═══════════════════════════════════════════════════════════════════════════

-- Cleanup request log (default: keep only 7 days)
CREATE OR REPLACE FUNCTION cleanup_request_log(retention_days INTEGER DEFAULT 7)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM request_log WHERE created_at < NOW() - (retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Cleanup sensor readings (default: keep 365 days)
CREATE OR REPLACE FUNCTION cleanup_sensor_readings(retention_days INTEGER DEFAULT 365)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    IF retention_days > 0 THEN
        DELETE FROM sensor_readings WHERE created_at < NOW() - (retention_days || ' days')::INTERVAL;
        GET DIAGNOSTICS deleted_count = ROW_COUNT;
        RETURN deleted_count;
    END IF;
    RETURN 0;
END;
$$ LANGUAGE plpgsql;

-- Cleanup security events (default: keep 730 days / 2 years)
CREATE OR REPLACE FUNCTION cleanup_security_events(retention_days INTEGER DEFAULT 730)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    IF retention_days > 0 THEN
        DELETE FROM security_events WHERE created_at < NOW() - (retention_days || ' days')::INTERVAL;
        GET DIAGNOSTICS deleted_count = ROW_COUNT;
        RETURN deleted_count;
    END IF;
    RETURN 0;
END;
$$ LANGUAGE plpgsql;

-- Cleanup audit log (default: keep 365 days)
CREATE OR REPLACE FUNCTION cleanup_audit_log(retention_days INTEGER DEFAULT 365)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    IF retention_days > 0 THEN
        DELETE FROM audit_log WHERE created_at < NOW() - (retention_days || ' days')::INTERVAL;
        GET DIAGNOSTICS deleted_count = ROW_COUNT;
        RETURN deleted_count;
    END IF;
    RETURN 0;
END;
$$ LANGUAGE plpgsql;

-- Master cleanup function: runs all cleanup tasks and returns summary
CREATE OR REPLACE FUNCTION cleanup_all(
    sensor_days INTEGER DEFAULT 365,
    security_days INTEGER DEFAULT 730,
    audit_days INTEGER DEFAULT 365,
    request_days INTEGER DEFAULT 7
)
RETURNS TABLE(
    table_name TEXT,
    deleted_rows INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 'sensor_readings'::TEXT, cleanup_sensor_readings(sensor_days)
    UNION ALL
    SELECT 'security_events'::TEXT, cleanup_security_events(security_days)
    UNION ALL
    SELECT 'audit_log'::TEXT, cleanup_audit_log(audit_days)
    UNION ALL
    SELECT 'request_log'::TEXT, cleanup_request_log(request_days);
END;
$$ LANGUAGE plpgsql;
