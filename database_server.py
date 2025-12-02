#!/usr/bin/env python3
"""
═══════════════════════════════════════════════════════════════════════════════
ClimaX Security System - Complete Audit Logging Server
Version 3.0
═══════════════════════════════════════════════════════════════════════════════

Receives all system events from ESP32 via HTTP POST and stores in PostgreSQL.

Features:
- Full event logging (sensors, alarm, climate, system, power)
- Climate data time series with accurate local timestamps
- Battery tracking
- Alarm history
- System health metrics
- Comprehensive query API
- Separate read/write API keys for security
- Dashboard-ready endpoints
- Connection pooling
- Data export

Usage:
    pip install flask psycopg2-binary python-dotenv flask-cors pytz
    python database_server.py

Environment Variables (.env file):
    See .env.template for all options
"""

import os
import json
import logging
import hashlib
from datetime import datetime, timedelta, timezone
from functools import wraps
from decimal import Decimal
from contextlib import contextmanager

from flask import Flask, request, jsonify, Response, g
from flask_cors import CORS
from dotenv import load_dotenv
import psycopg2
from psycopg2.extras import RealDictCursor, Json
from psycopg2 import pool

# Try to import pytz for timezone handling
try:
    import pytz
    HAS_PYTZ = True
except ImportError:
    HAS_PYTZ = False

# Load environment variables
load_dotenv()

# ═══════════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════════

def get_database_url():
    """Build database URL from environment variables."""
    url = os.getenv('DATABASE_URL')
    if url:
        return url
    
    host = os.getenv('DB_HOST', 'localhost')
    port = os.getenv('DB_PORT', '5432')
    name = os.getenv('DB_NAME', 'climax')
    user = os.getenv('DB_USER', 'climax')
    password = os.getenv('DB_PASSWORD', 'climax')
    
    return f"postgresql://{user}:{password}@{host}:{port}/{name}"

DATABASE_URL = get_database_url()
DB_POOL_MIN = int(os.getenv('DB_POOL_MIN_CONN', 2))
DB_POOL_MAX = int(os.getenv('DB_POOL_MAX_CONN', 10))

# API Keys - separate read and write access
API_KEY_WRITE = os.getenv('API_KEY_WRITE', '')
API_KEY_READ = os.getenv('API_KEY_READ', '')
API_KEY_LEGACY = os.getenv('API_KEY', '')  # Backwards compatibility

# Server config
PORT = int(os.getenv('PORT', 5000))
HOST = os.getenv('HOST', '0.0.0.0')
DEBUG = os.getenv('DEBUG', 'false').lower() == 'true'

# Timezone
TIMEZONE = os.getenv('TIMEZONE', 'Europe/Berlin')
if HAS_PYTZ:
    try:
        LOCAL_TZ = pytz.timezone(TIMEZONE)
    except pytz.exceptions.UnknownTimeZoneError:
        LOCAL_TZ = pytz.UTC
else:
    LOCAL_TZ = None

# Data retention settings (in days, 0 = keep forever)
DATA_RETENTION_DAYS = int(os.getenv('DATA_RETENTION_DAYS', 365))
SECURITY_RETENTION_DAYS = int(os.getenv('SECURITY_RETENTION_DAYS', 730))
AUDIT_RETENTION_DAYS = int(os.getenv('AUDIT_RETENTION_DAYS', 365))

# Logging config
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
LOG_FILE = os.getenv('LOG_FILE', '')
LOG_REQUESTS = os.getenv('LOG_REQUESTS', 'false').lower() == 'true'

# CORS
CORS_ORIGINS = os.getenv('CORS_ORIGINS', '*')

# Setup logging
log_handlers = [logging.StreamHandler()]
if LOG_FILE:
    log_handlers.append(logging.FileHandler(LOG_FILE))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=log_handlers
)
logger = logging.getLogger(__name__)

# Flask app
app = Flask(__name__)

# Configure CORS
if CORS_ORIGINS == '*':
    CORS(app)
else:
    CORS(app, origins=CORS_ORIGINS.split(','))


# ═══════════════════════════════════════════════════════════════════════════════
# Database Connection Pool
# ═══════════════════════════════════════════════════════════════════════════════

db_pool = None

def init_db_pool():
    """Initialize the database connection pool."""
    global db_pool
    try:
        db_pool = pool.ThreadedConnectionPool(
            DB_POOL_MIN,
            DB_POOL_MAX,
            DATABASE_URL,
            cursor_factory=RealDictCursor
        )
        logger.info(f"✓ Database pool initialized (min={DB_POOL_MIN}, max={DB_POOL_MAX})")
        return True
    except Exception as e:
        logger.error(f"✗ Database pool initialization failed: {e}")
        return False

@contextmanager
def get_db():
    """Get a database connection from the pool with climax schema."""
    conn = None
    try:
        conn = db_pool.getconn()
        # Set search path to use ONLY climax schema
        cur = conn.cursor()
        cur.execute("SET search_path TO climax")
        cur.close()
        yield conn
    finally:
        if conn:
            db_pool.putconn(conn)

def init_db():
    """Check database connection on startup."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1")
            cur.close()
        logger.info("✓ Database connection successful")
        return True
    except Exception as e:
        logger.error(f"✗ Database connection failed: {e}")
        return False


# Custom JSON encoder for Decimal and datetime
class CustomJSONEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        if isinstance(obj, datetime):
            return obj.isoformat()
        return super().default(obj)

app.json_encoder = CustomJSONEncoder


# ═══════════════════════════════════════════════════════════════════════════════
# Timestamp Helpers
# ═══════════════════════════════════════════════════════════════════════════════

def parse_device_time(data):
    """
    Parse device timestamp from request data.
    Accepts: ISO format string, Unix timestamp (seconds or milliseconds)
    Returns: timezone-aware datetime or None
    """
    device_time = data.get('device_time') or data.get('timestamp') or data.get('event_time')
    
    if not device_time:
        return None
    
    try:
        if isinstance(device_time, str):
            # Try ISO format
            dt = datetime.fromisoformat(device_time.replace('Z', '+00:00'))
            if dt.tzinfo is None and LOCAL_TZ:
                dt = LOCAL_TZ.localize(dt)
            return dt
        elif isinstance(device_time, (int, float)):
            # Unix timestamp - check if milliseconds
            if device_time > 1e12:  # Milliseconds
                device_time = device_time / 1000
            dt = datetime.fromtimestamp(device_time, tz=timezone.utc)
            return dt
    except (ValueError, TypeError) as e:
        logger.debug(f"Could not parse device_time: {device_time} - {e}")
    
    return None

def get_local_now():
    """Get current time in local timezone."""
    if LOCAL_TZ:
        return datetime.now(LOCAL_TZ)
    return datetime.now(timezone.utc)


# ═══════════════════════════════════════════════════════════════════════════════
# Authentication
# ═══════════════════════════════════════════════════════════════════════════════

def require_api_key_write(f):
    """Require write API key for POST/PUT/DELETE operations."""
    @wraps(f)
    def decorated(*args, **kwargs):
        provided_key = request.headers.get('X-API-Key', '')
        
        # Check write key
        if API_KEY_WRITE and provided_key == API_KEY_WRITE:
            return f(*args, **kwargs)
        
        # Check legacy key (has full access)
        if API_KEY_LEGACY and provided_key == API_KEY_LEGACY:
            return f(*args, **kwargs)
        
        # If no keys are configured, allow access (development mode)
        if not API_KEY_WRITE and not API_KEY_LEGACY:
            return f(*args, **kwargs)
        
        return jsonify({'error': 'Unauthorized - Invalid or missing write API key'}), 401
    return decorated

def require_api_key_read(f):
    """Require read API key for GET operations."""
    @wraps(f)
    def decorated(*args, **kwargs):
        provided_key = request.headers.get('X-API-Key', '')
        
        # Check read key
        if API_KEY_READ and provided_key == API_KEY_READ:
            return f(*args, **kwargs)
        
        # Check write key (has read access too)
        if API_KEY_WRITE and provided_key == API_KEY_WRITE:
            return f(*args, **kwargs)
        
        # Check legacy key (has full access)
        if API_KEY_LEGACY and provided_key == API_KEY_LEGACY:
            return f(*args, **kwargs)
        
        # If no keys are configured, allow access (development mode)
        if not API_KEY_READ and not API_KEY_WRITE and not API_KEY_LEGACY:
            return f(*args, **kwargs)
        
        return jsonify({'error': 'Unauthorized - Invalid or missing API key'}), 401
    return decorated

# Backwards compatible decorator
def require_api_key(f):
    """Legacy decorator - maps to read access."""
    return require_api_key_read(f)


# ═══════════════════════════════════════════════════════════════════════════════
# Logging API Endpoints
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/api/log/event', methods=['POST'])
@require_api_key_write
def log_event():
    """
    Log a general event.
    
    Expected JSON:
    {
        "bridge_mac": "AA:BB:CC:DD:EE:FF",
        "sensor_mac": "11:22:33:44:55:66",  // optional
        "sensor_name": "Balkontür",          // optional
        "room": "Wohnzimmer",                // optional
        "category": "sensor",                // sensor|alarm|climate|system|communication|power|config
        "event_type": "contact_opened",
        "severity": 0,                       // 0=info, 1=warning, 2=error, 3=critical
        "old_value": "closed",               // optional
        "new_value": "open",                 // optional
        "message": "Door opened",            // optional
        "device_time": "2024-01-15T10:30:00+01:00",  // optional - local time from ESP32
        "esp_millis": 123456789,             // optional - ESP32 millis()
        "state_snapshot": {...},             // optional - full sensor state
        "metadata": {...}                    // optional - additional data
    }
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        device_time = parse_device_time(data)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                INSERT INTO event_log (
                    bridge_mac, sensor_mac, sensor_name, room,
                    category, event_type, severity,
                    old_value, new_value, message,
                    device_time, esp_millis,
                    state_snapshot, metadata
                ) VALUES (
                    %(bridge_mac)s, %(sensor_mac)s, %(sensor_name)s, %(room)s,
                    %(category)s, %(event_type)s, %(severity)s,
                    %(old_value)s, %(new_value)s, %(message)s,
                    %(device_time)s, %(esp_millis)s,
                    %(state_snapshot)s, %(metadata)s
                )
                RETURNING id, local_time
            """, {
                'bridge_mac': data.get('bridge_mac'),
                'sensor_mac': data.get('sensor_mac'),
                'sensor_name': data.get('sensor_name'),
                'room': data.get('room'),
                'category': data.get('category', 'sensor'),
                'event_type': data.get('event_type'),
                'severity': data.get('severity', 0),
                'old_value': data.get('old_value'),
                'new_value': data.get('new_value'),
                'message': data.get('message'),
                'device_time': device_time,
                'esp_millis': data.get('esp_millis'),
                'state_snapshot': Json(data.get('state_snapshot')) if data.get('state_snapshot') else None,
                'metadata': Json(data.get('metadata')) if data.get('metadata') else None
            })
            
            result = cur.fetchone()
            conn.commit()
        
        logger.info(f"Event #{result['id']}: {data.get('event_type')} - {data.get('sensor_name', 'SYSTEM')}")
        return jsonify({
            'success': True, 
            'id': result['id'],
            'local_time': result['local_time'].isoformat() if result['local_time'] else None
        }), 201
        
    except Exception as e:
        logger.error(f"Error logging event: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/log/climate', methods=['POST'])
@require_api_key_write
def log_climate():
    """
    Log climate reading for a sensor.
    
    Expected JSON:
    {
        "sensor_mac": "11:22:33:44:55:66",
        "sensor_name": "Balkontür",
        "room": "Wohnzimmer",
        "temperature": 21.5,
        "humidity": 55.0,
        "pressure": 1013.25,
        "dew_point": 12.3,
        "mold_risk_score": 15,
        "heat_index": 22.1,
        "contact_open": false,
        "alert_level": "ok",
        "device_time": "2024-01-15T10:30:00+01:00"  // optional - local time from device
    }
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        device_time = parse_device_time(data)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                INSERT INTO climate_readings (
                    sensor_mac, sensor_name, room,
                    temperature, humidity, pressure, dew_point,
                    mold_risk_score, heat_index, contact_open, alert_level,
                    device_time
                ) VALUES (
                    %(sensor_mac)s, %(sensor_name)s, %(room)s,
                    %(temperature)s, %(humidity)s, %(pressure)s, %(dew_point)s,
                    %(mold_risk_score)s, %(heat_index)s, %(contact_open)s, %(alert_level)s,
                    %(device_time)s
                )
                RETURNING id, local_time
            """, {
                **data,
                'device_time': device_time
            })
            
            result = cur.fetchone()
            
            # Also update sensor current state
            cur.execute("""
                UPDATE sensors SET
                    temperature = %(temperature)s,
                    humidity = %(humidity)s,
                    pressure = %(pressure)s,
                    dew_point = %(dew_point)s,
                    contact_open = %(contact_open)s,
                    climate_alert = %(alert_level)s,
                    last_seen = NOW()
                WHERE mac_address = %(sensor_mac)s
            """, data)
            
            conn.commit()
        
        return jsonify({
            'success': True, 
            'id': result['id'],
            'local_time': result['local_time'].isoformat() if result['local_time'] else None
        }), 201
        
    except Exception as e:
        logger.error(f"Error logging climate: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/log/battery', methods=['POST'])
@require_api_key_write
def log_battery():
    """
    Log battery reading.
    
    Expected JSON:
    {
        "device_type": "sensor",  // or "bridge"
        "device_mac": "11:22:33:44:55:66",
        "device_name": "Balkontür",
        "battery_level": 85,
        "battery_voltage": 4.02,
        "is_charging": false,
        "device_time": "2024-01-15T10:30:00+01:00"  // optional
    }
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        device_time = parse_device_time(data)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            # Get previous reading for rate calculation
            cur.execute("""
                SELECT battery_level, local_time FROM battery_readings
                WHERE device_mac = %(device_mac)s
                ORDER BY local_time DESC LIMIT 1
            """, data)
            
            prev = cur.fetchone()
            level_change = None
            time_delta = None
            
            if prev:
                level_change = data.get('battery_level', 0) - prev['battery_level']
                time_delta = int((get_local_now() - prev['local_time']).total_seconds())
            
            cur.execute("""
                INSERT INTO battery_readings (
                    device_type, device_mac, device_name,
                    battery_level, battery_voltage, is_charging,
                    level_change, time_delta_sec, device_time
                ) VALUES (
                    %(device_type)s, %(device_mac)s, %(device_name)s,
                    %(battery_level)s, %(battery_voltage)s, %(is_charging)s,
                    %(level_change)s, %(time_delta)s, %(device_time)s
                )
                RETURNING id, local_time
            """, {
                **data,
                'level_change': level_change,
                'time_delta': time_delta,
                'device_time': device_time
            })
            
            result = cur.fetchone()
            
            # Update sensor/bridge current state
            if data.get('device_type') == 'sensor':
                cur.execute("""
                    UPDATE sensors SET
                        battery_level = %(battery_level)s,
                        is_charging = %(is_charging)s,
                        last_seen = NOW()
                    WHERE mac_address = %(device_mac)s
                """, data)
            elif data.get('device_type') == 'bridge':
                cur.execute("""
                    UPDATE bridges SET
                        battery_level = %(battery_level)s,
                        battery_voltage = %(battery_voltage)s,
                        last_seen = NOW()
                    WHERE mac_address = %(device_mac)s
                """, data)
            
            conn.commit()
        
        return jsonify({
            'success': True, 
            'id': result['id'],
            'local_time': result['local_time'].isoformat() if result['local_time'] else None
        }), 201
        
    except Exception as e:
        logger.error(f"Error logging battery: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/log/alarm', methods=['POST'])
@require_api_key_write
def log_alarm():
    """
    Log alarm event.
    
    Expected JSON:
    {
        "bridge_mac": "AA:BB:CC:DD:EE:FF",
        "event_type": "triggered",  // armed, disarmed, triggered, etc.
        "alarm_mode": "away",
        "previous_mode": "disarmed",
        "trigger_sensor": "11:22:33:44:55:66",  // optional
        "trigger_name": "Balkontür",             // optional
        "trigger_room": "Wohnzimmer",            // optional
        "duration_seconds": 30,                  // optional
        "was_silenced": false,
        "was_entry_delay": false,
        "was_exit_delay": false,
        "message": "Alarm triggered by Balkontür",
        "device_time": "2024-01-15T10:30:00+01:00"  // optional
    }
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        device_time = parse_device_time(data)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                INSERT INTO alarm_events (
                    bridge_mac, event_type, alarm_mode, previous_mode,
                    trigger_sensor, trigger_name, trigger_room,
                    duration_seconds, was_silenced, was_entry_delay, was_exit_delay,
                    message, device_time
                ) VALUES (
                    %(bridge_mac)s, %(event_type)s, %(alarm_mode)s, %(previous_mode)s,
                    %(trigger_sensor)s, %(trigger_name)s, %(trigger_room)s,
                    %(duration_seconds)s, %(was_silenced)s, %(was_entry_delay)s, %(was_exit_delay)s,
                    %(message)s, %(device_time)s
                )
                RETURNING id, local_time
            """, {
                'bridge_mac': data.get('bridge_mac'),
                'event_type': data.get('event_type'),
                'alarm_mode': data.get('alarm_mode'),
                'previous_mode': data.get('previous_mode'),
                'trigger_sensor': data.get('trigger_sensor'),
                'trigger_name': data.get('trigger_name'),
                'trigger_room': data.get('trigger_room'),
                'duration_seconds': data.get('duration_seconds'),
                'was_silenced': data.get('was_silenced', False),
                'was_entry_delay': data.get('was_entry_delay', False),
                'was_exit_delay': data.get('was_exit_delay', False),
                'message': data.get('message'),
                'device_time': device_time
            })
            
            result = cur.fetchone()
            
            # Update bridge state
            if data.get('alarm_mode'):
                cur.execute("""
                    UPDATE bridges SET
                        alarm_mode = %(alarm_mode)s,
                        last_seen = NOW()
                    WHERE mac_address = %(bridge_mac)s
                """, data)
            
            conn.commit()
        
        logger.info(f"Alarm event: {data.get('event_type')} - {data.get('message')}")
        return jsonify({
            'success': True, 
            'id': result['id'],
            'local_time': result['local_time'].isoformat() if result['local_time'] else None
        }), 201
        
    except Exception as e:
        logger.error(f"Error logging alarm: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/log/state', methods=['POST'])
@require_api_key_write
def log_bridge_state():
    """
    Log bridge/alarm state snapshot for auditing.
    
    Expected JSON:
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
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        with get_db() as conn:
            cur = conn.cursor()
            
            # Log as an event for auditing
            cur.execute("""
                INSERT INTO event_log (
                    bridge_mac, sensor_mac, category, event_type,
                    message, metadata
                ) VALUES (
                    %(bridge_mac)s, NULL, 'system', 'state_snapshot',
                    %(message)s, %(metadata)s
                )
                RETURNING id, local_time
            """, {
                'bridge_mac': data.get('bridge_mac'),
                'message': f"State: {data.get('alarm_mode_name', 'unknown')} | Armed: {data.get('is_armed', False)} | Exit: {data.get('in_exit_delay', False)} | Entry: {data.get('in_entry_delay', False)} | Sensors: {data.get('sensors_online', 0)}/{data.get('sensors_total', 0)}",
                'metadata': Json(data)
            })
            
            result = cur.fetchone()
            
            # Update bridge current state
            cur.execute("""
                UPDATE bridges SET
                    alarm_mode = %(alarm_mode_name)s,
                    is_armed = %(is_armed)s,
                    uptime_seconds = %(uptime_seconds)s,
                    last_seen = NOW()
                WHERE mac_address = %(bridge_mac)s
            """, data)
            
            conn.commit()
        
        return jsonify({
            'success': True, 
            'id': result['id'],
            'local_time': result['local_time'].isoformat() if result['local_time'] else None
        }), 201
        
    except Exception as e:
        logger.error(f"Error logging state: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/log/metrics', methods=['POST'])
@require_api_key_write
def log_metrics():
    """
    Log system health metrics.
    
    Expected JSON:
    {
        "bridge_mac": "AA:BB:CC:DD:EE:FF",
        "free_heap": 150000,
        "min_free_heap": 120000,
        "heap_fragmentation": 5,
        "wifi_rssi": -55,
        "wifi_channel": 6,
        "uptime_seconds": 86400,
        "loop_time_us": 1500,
        "sensors_online": 3,
        "sensors_total": 4,
        "events_queued": 0,
        "device_time": "2024-01-15T10:30:00+01:00"  // optional
    }
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        device_time = parse_device_time(data)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                INSERT INTO system_metrics (
                    bridge_mac, free_heap, min_free_heap, heap_fragmentation,
                    wifi_rssi, wifi_channel, uptime_seconds, loop_time_us,
                    sensors_online, sensors_total, events_queued, device_time
                ) VALUES (
                    %(bridge_mac)s, %(free_heap)s, %(min_free_heap)s, %(heap_fragmentation)s,
                    %(wifi_rssi)s, %(wifi_channel)s, %(uptime_seconds)s, %(loop_time_us)s,
                    %(sensors_online)s, %(sensors_total)s, %(events_queued)s, %(device_time)s
                )
                RETURNING id, local_time
            """, {
                'bridge_mac': data.get('bridge_mac'),
                'free_heap': data.get('free_heap'),
                'min_free_heap': data.get('min_free_heap'),
                'heap_fragmentation': data.get('heap_fragmentation', 0),
                'wifi_rssi': data.get('wifi_rssi'),
                'wifi_channel': data.get('wifi_channel'),
                'uptime_seconds': data.get('uptime_seconds'),
                'loop_time_us': data.get('loop_time_us', 0),
                'sensors_online': data.get('sensors_online'),
                'sensors_total': data.get('sensors_total'),
                'events_queued': data.get('events_queued', 0),
                'device_time': device_time
            })
            
            result = cur.fetchone()
            
            # Update bridge
            cur.execute("""
                UPDATE bridges SET
                    free_heap = %(free_heap)s,
                    uptime_seconds = %(uptime_seconds)s,
                    last_seen = NOW()
                WHERE mac_address = %(bridge_mac)s
            """, data)
            
            conn.commit()
        
        return jsonify({
            'success': True, 
            'id': result['id'],
            'local_time': result['local_time'].isoformat() if result['local_time'] else None
        }), 201
        
    except Exception as e:
        logger.error(f"Error logging metrics: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/log/sensor-state', methods=['POST'])
@require_api_key_write
def log_sensor_state():
    """
    Update sensor current state (from periodic reports).
    
    Expected JSON:
    {
        "bridge_mac": "AA:BB:CC:DD:EE:FF",
        "sensor_mac": "11:22:33:44:55:66",
        "name": "Balkontür",
        "room": "Wohnzimmer",
        "is_entry_exit": true,
        "is_active": true,
        "contact_open": false,
        "temperature": 21.5,
        "humidity": 55.0,
        "pressure": 1013.25,
        "dew_point": 12.3,
        "battery_level": 85,
        "is_charging": false,
        "is_online": true,
        "operational_mode": "normal",
        "bypass_active": false,
        "night_bypass": false,
        "climate_alert": "ok"
    }
    """
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data'}), 400
        
        # Support both formats - the comprehensive snapshot from ESP32 and the simpler format
        sensor_mac = data.get('sensor_mac')
        bridge_mac = data.get('bridge_mac')
        
        # If this is a snapshot from ESP32 logSensorStateSnapshot (has 'online' key), log it as an event
        if sensor_mac and data.get('online') is not None:
            with get_db() as conn:
                cur = conn.cursor()
                
                # Log as event for audit trail
                cur.execute("""
                    INSERT INTO event_log (
                        bridge_mac, sensor_mac, category, event_type,
                        message, metadata
                    ) VALUES (
                        %(bridge_mac)s, %(sensor_mac)s, 'sensor', 'state_snapshot',
                        %(message)s, %(metadata)s
                    )
                    RETURNING id, local_time
                """, {
                    'bridge_mac': bridge_mac,
                    'sensor_mac': sensor_mac,
                    'message': f"{data.get('sensor_name', 'Sensor')} @ {data.get('room', 'Unknown')} | {'Online' if data.get('online', False) else 'OFFLINE'} | Contact: {'OPEN' if data.get('contact_open', False) else 'closed'} | Bypass: {data.get('bypassed', False)} | Night: {data.get('night_bypassed', False)} | T:{data.get('temperature', 0):.1f}C H:{data.get('humidity', 0):.0f}% | Bat:{data.get('battery_level', 0)}%",
                    'metadata': Json(data)
                })
                
                result = cur.fetchone()
                conn.commit()
            
            return jsonify({
                'success': True,
                'id': result['id'],
                'local_time': result['local_time'].isoformat() if result['local_time'] else None
            }), 201
        
        # Original sensor state update (for real-time current state)
        # Handle partial updates - only update fields that are provided
        with get_db() as conn:
            cur = conn.cursor()
            
            # Build dynamic update for partial updates
            # Use COALESCE to preserve existing values when new value is NULL
            # Cast ENUM default values properly
            cur.execute("""
                INSERT INTO sensors (
                    mac_address, bridge_mac, name, room, is_entry_exit, is_active,
                    contact_open, temperature, humidity, pressure, dew_point,
                    battery_level, is_charging, is_online, operational_mode,
                    bypass_active, night_bypass, climate_alert, last_seen
                ) VALUES (
                    %(sensor_mac)s, %(bridge_mac)s, %(sensor_name)s, %(room)s, 
                    COALESCE(%(is_entry_exit)s, false), COALESCE(%(is_active)s, true),
                    %(contact_open)s, %(temperature)s, %(humidity)s, %(pressure)s, %(dew_point)s,
                    %(battery_level)s, %(is_charging)s, COALESCE(%(is_online)s, true), 
                    COALESCE(%(operational_mode)s::sensor_mode, 'normal'::sensor_mode),
                    COALESCE(%(bypass_active)s, false), COALESCE(%(night_bypass)s, false), 
                    COALESCE(%(climate_alert)s::climate_alert_level, 'ok'::climate_alert_level), NOW()
                )
                ON CONFLICT (mac_address) DO UPDATE SET
                    bridge_mac = COALESCE(EXCLUDED.bridge_mac, sensors.bridge_mac),
                    name = COALESCE(EXCLUDED.name, sensors.name),
                    room = COALESCE(EXCLUDED.room, sensors.room),
                    is_entry_exit = COALESCE(EXCLUDED.is_entry_exit, sensors.is_entry_exit),
                    is_active = COALESCE(EXCLUDED.is_active, sensors.is_active),
                    contact_open = COALESCE(EXCLUDED.contact_open, sensors.contact_open),
                    temperature = COALESCE(EXCLUDED.temperature, sensors.temperature),
                    humidity = COALESCE(EXCLUDED.humidity, sensors.humidity),
                    pressure = COALESCE(EXCLUDED.pressure, sensors.pressure),
                    dew_point = COALESCE(EXCLUDED.dew_point, sensors.dew_point),
                    battery_level = COALESCE(EXCLUDED.battery_level, sensors.battery_level),
                    is_charging = COALESCE(EXCLUDED.is_charging, sensors.is_charging),
                    is_online = COALESCE(EXCLUDED.is_online, sensors.is_online),
                    operational_mode = COALESCE(EXCLUDED.operational_mode, sensors.operational_mode),
                    bypass_active = COALESCE(EXCLUDED.bypass_active, sensors.bypass_active),
                    night_bypass = COALESCE(EXCLUDED.night_bypass, sensors.night_bypass),
                    climate_alert = COALESCE(EXCLUDED.climate_alert, sensors.climate_alert),
                    last_seen = NOW()
            """, {
                'sensor_mac': data.get('sensor_mac'),
                'bridge_mac': data.get('bridge_mac'),
                'sensor_name': data.get('sensor_name') or data.get('name'),
                'room': data.get('room'),
                'is_entry_exit': data.get('is_entry_exit'),
                'is_active': data.get('is_active'),
                'contact_open': data.get('contact_open'),
                'temperature': data.get('temperature'),
                'humidity': data.get('humidity'),
                'pressure': data.get('pressure'),
                'dew_point': data.get('dew_point'),
                'battery_level': data.get('battery_level'),
                'is_charging': data.get('is_charging'),
                'is_online': data.get('is_online'),
                'operational_mode': data.get('operational_mode'),
                'bypass_active': data.get('bypass_active'),
                'night_bypass': data.get('night_bypass'),
                'climate_alert': data.get('climate_alert')
            })
            
            conn.commit()
        
        return jsonify({'success': True}), 200
        
    except Exception as e:
        logger.error(f"Error updating sensor state: {e}")
        return jsonify({'error': str(e)}), 500


# ═══════════════════════════════════════════════════════════════════════════════
# Query API Endpoints
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/api/events', methods=['GET'])
@require_api_key_read
def get_events():
    """
    Query events with filters.
    
    Query parameters:
        limit, offset, sensor, room, category, event_type, 
        severity, from, to
    """
    try:
        limit = min(int(request.args.get('limit', 100)), 1000)
        offset = int(request.args.get('offset', 0))
        
        conditions = []
        params = []
        
        if request.args.get('sensor'):
            conditions.append("(sensor_mac = %s OR sensor_name ILIKE %s)")
            params.extend([request.args.get('sensor'), f"%{request.args.get('sensor')}%"])
        
        if request.args.get('room'):
            conditions.append("room ILIKE %s")
            params.append(f"%{request.args.get('room')}%")
        
        if request.args.get('category'):
            conditions.append("category = %s")
            params.append(request.args.get('category'))
        
        if request.args.get('event_type'):
            conditions.append("event_type = %s")
            params.append(request.args.get('event_type'))
        
        if request.args.get('severity'):
            conditions.append("severity >= %s")
            params.append(int(request.args.get('severity')))
        
        if request.args.get('from'):
            conditions.append("local_time >= %s")
            params.append(request.args.get('from'))
        
        if request.args.get('to'):
            conditions.append("local_time <= %s")
            params.append(request.args.get('to'))
        
        where = "WHERE " + " AND ".join(conditions) if conditions else ""
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute(f"SELECT COUNT(*) as count FROM event_log {where}", params)
            total = cur.fetchone()['count']
            
            cur.execute(f"""
                SELECT id, local_time, created_at, device_time, bridge_mac, sensor_mac,
                       sensor_name, room, category, event_type, severity,
                       old_value, new_value, message, metadata
                FROM event_log {where}
                ORDER BY local_time DESC
                LIMIT %s OFFSET %s
            """, params + [limit, offset])
            
            events = cur.fetchall()
        
        return jsonify({
            'total': total,
            'limit': limit,
            'offset': offset,
            'events': [dict(e) for e in events]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/climate/<sensor_mac>', methods=['GET'])
@require_api_key_read
def get_climate_history(sensor_mac):
    """Get climate history for a sensor."""
    try:
        hours = int(request.args.get('hours', 24))
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                SELECT local_time, temperature, humidity, pressure, dew_point,
                       mold_risk_score, contact_open, alert_level
                FROM climate_readings
                WHERE sensor_mac = %s
                    AND local_time > NOW() - INTERVAL '%s hours'
                ORDER BY local_time DESC
            """, (sensor_mac, hours))
            
            readings = cur.fetchall()
        
        return jsonify({
            'sensor_mac': sensor_mac,
            'hours': hours,
            'readings': [dict(r) for r in readings]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/battery/<device_mac>', methods=['GET'])
@require_api_key_read
def get_battery_history(device_mac):
    """Get battery history for a device."""
    try:
        days = int(request.args.get('days', 7))
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                SELECT local_time, battery_level, battery_voltage, is_charging,
                       level_change, time_delta_sec
                FROM battery_readings
                WHERE device_mac = %s
                    AND local_time > NOW() - INTERVAL '%s days'
                ORDER BY local_time DESC
            """, (device_mac, days))
            
            readings = cur.fetchall()
        
        return jsonify({
            'device_mac': device_mac,
            'days': days,
            'readings': [dict(r) for r in readings]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/alarms', methods=['GET'])
@require_api_key_read
def get_alarm_history():
    """Get alarm event history."""
    try:
        limit = min(int(request.args.get('limit', 100)), 500)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                SELECT * FROM alarm_events
                ORDER BY local_time DESC
                LIMIT %s
            """, (limit,))
            
            events = cur.fetchall()
        
        return jsonify({
            'events': [dict(e) for e in events]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/sensors', methods=['GET'])
@require_api_key_read
def get_sensors():
    """Get all sensors with current state."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("SELECT * FROM v_sensor_current_state")
            sensors = cur.fetchall()
        
        return jsonify({
            'sensors': [dict(s) for s in sensors]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/sensors/<mac>', methods=['GET'])
@require_api_key_read
def get_sensor(mac):
    """Get single sensor details with recent history."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            # Current state
            cur.execute("SELECT * FROM sensors WHERE mac_address = %s", (mac,))
            sensor = cur.fetchone()
            
            if not sensor:
                return jsonify({'error': 'Sensor not found'}), 404
            
            # Recent events
            cur.execute("""
                SELECT local_time, event_type, message, old_value, new_value
                FROM event_log
                WHERE sensor_mac = %s
                ORDER BY local_time DESC
                LIMIT 50
            """, (mac,))
            events = cur.fetchall()
            
            # Recent climate
            cur.execute("""
                SELECT local_time, temperature, humidity, pressure
                FROM climate_readings
                WHERE sensor_mac = %s
                ORDER BY local_time DESC
                LIMIT 24
            """, (mac,))
            climate = cur.fetchall()
            
            # Battery trend
            cur.execute("""
                SELECT local_time, battery_level
                FROM battery_readings
                WHERE device_mac = %s
                ORDER BY local_time DESC
                LIMIT 100
            """, (mac,))
            battery = cur.fetchall()
        
        return jsonify({
            'sensor': dict(sensor),
            'recent_events': [dict(e) for e in events],
            'climate_history': [dict(c) for c in climate],
            'battery_history': [dict(b) for b in battery]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/stats/daily', methods=['GET'])
@require_api_key_read
def get_daily_stats():
    """Get daily statistics."""
    try:
        days = int(request.args.get('days', 7))
        
        with get_db() as conn:
            cur = conn.cursor()
            
            # Events per day by type
            cur.execute("""
                SELECT 
                    DATE(local_time AT TIME ZONE %s) as date,
                    category,
                    COUNT(*) as count
                FROM event_log
                WHERE local_time > NOW() - INTERVAL '%s days'
                GROUP BY DATE(local_time AT TIME ZONE %s), category
                ORDER BY date DESC, category
            """, (TIMEZONE, days, TIMEZONE))
            event_stats = cur.fetchall()
            
            # Climate averages per room
            cur.execute("""
                SELECT * FROM v_daily_climate
                WHERE date > CURRENT_DATE - %s
            """, (days,))
            climate_stats = cur.fetchall()
            
            # Contact activity
            cur.execute("""
                SELECT * FROM v_contact_activity
                WHERE date > CURRENT_DATE - %s
            """, (days,))
            contact_stats = cur.fetchall()
        
        return jsonify({
            'days': days,
            'events_by_category': [dict(e) for e in event_stats],
            'climate_by_room': [dict(c) for c in climate_stats],
            'contact_activity': [dict(c) for c in contact_stats]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/export/events', methods=['GET'])
@require_api_key_read
def export_events():
    """Export events as CSV."""
    try:
        from_date = request.args.get('from', (get_local_now() - timedelta(days=7)).isoformat())
        to_date = request.args.get('to', get_local_now().isoformat())
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                SELECT local_time, category, event_type, sensor_name, room,
                       severity, old_value, new_value, message
                FROM event_log
                WHERE local_time BETWEEN %s AND %s
                ORDER BY local_time DESC
            """, (from_date, to_date))
            
            events = cur.fetchall()
        
        # Build CSV
        lines = ['local_time,category,event_type,sensor,room,severity,old_value,new_value,message']
        for e in events:
            line = ','.join([
                str(e['local_time']),
                str(e['category'] or ''),
                str(e['event_type'] or ''),
                str(e['sensor_name'] or ''),
                str(e['room'] or ''),
                str(e['severity'] or '0'),
                f'"{e["old_value"] or ""}"',
                f'"{e["new_value"] or ""}"',
                f'"{e["message"] or ""}"'
            ])
            lines.append(line)
        
        csv_content = '\n'.join(lines)
        
        return Response(
            csv_content,
            mimetype='text/csv',
            headers={'Content-Disposition': f'attachment; filename=events_{from_date[:10]}_{to_date[:10]}.csv'}
        )
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ═══════════════════════════════════════════════════════════════════════════════
# Dashboard API Endpoints
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/api/dashboard/summary', methods=['GET'])
@require_api_key_read
def get_dashboard_summary():
    """Get dashboard summary for quick overview."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("SELECT * FROM v_dashboard_summary")
            summary = cur.fetchone()
        
        return jsonify(dict(summary) if summary else {})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/dashboard/recent-activity', methods=['GET'])
@require_api_key_read
def get_recent_activity():
    """Get recent activity for dashboard feed."""
    try:
        limit = min(int(request.args.get('limit', 50)), 200)
        
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                SELECT id, local_time, category, event_type, severity,
                       sensor_name, room, message
                FROM event_log
                ORDER BY local_time DESC
                LIMIT %s
            """, (limit,))
            
            events = cur.fetchall()
        
        return jsonify({
            'events': [dict(e) for e in events]
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/dashboard/climate-current', methods=['GET'])
@require_api_key_read
def get_current_climate():
    """Get current climate readings for all sensors."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("""
                SELECT DISTINCT ON (sensor_mac)
                    sensor_mac, sensor_name, room, local_time,
                    temperature, humidity, pressure, dew_point,
                    mold_risk_score, alert_level, contact_open
                FROM climate_readings
                ORDER BY sensor_mac, local_time DESC
            """)
            
            readings = cur.fetchall()
        
        return jsonify({
            'readings': [dict(r) for r in readings],
            'timestamp': get_local_now().isoformat()
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/health', methods=['GET'])
def health_check():
    """Health check endpoint (no auth required for monitoring)."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            cur.execute("SELECT COUNT(*) as count FROM event_log")
            events = cur.fetchone()['count']
            
            cur.execute("SELECT COUNT(*) as count FROM sensors")
            sensors = cur.fetchone()['count']
            
            cur.execute("SELECT COUNT(*) as count FROM sensors WHERE is_online = true")
            online = cur.fetchone()['count']
        
        return jsonify({
            'status': 'healthy',
            'database': 'connected',
            'timezone': TIMEZONE,
            'total_events': events,
            'total_sensors': sensors,
            'sensors_online': online,
            'server_time': get_local_now().isoformat()
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 500


@app.route('/api/server/time', methods=['GET'])
def get_server_time():
    """Get current server time (useful for ESP32 sync)."""
    now = get_local_now()
    return jsonify({
        'iso': now.isoformat(),
        'unix': int(now.timestamp()),
        'timezone': TIMEZONE
    })


# ═══════════════════════════════════════════════════════════════════════════════
# Data Retention & Cleanup Endpoints
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/api/admin/retention', methods=['GET'])
@require_api_key_write
def get_retention_settings():
    """Get current data retention settings."""
    return jsonify({
        'sensor_readings_days': DATA_RETENTION_DAYS,
        'security_events_days': SECURITY_RETENTION_DAYS,
        'audit_log_days': AUDIT_RETENTION_DAYS,
        'description': {
            'sensor_readings_days': 'How long to keep sensor/climate readings',
            'security_events_days': 'How long to keep security events',
            'audit_log_days': 'How long to keep audit and request logs'
        },
        'note': '0 = keep forever'
    })


@app.route('/api/admin/cleanup', methods=['POST'])
@require_api_key_write
def trigger_cleanup():
    """Manually trigger data cleanup based on retention settings."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            results = {}
            
            # Cleanup sensor readings
            if DATA_RETENTION_DAYS > 0:
                cur.execute("""
                    DELETE FROM sensor_readings 
                    WHERE created_at < NOW() - (%s || ' days')::INTERVAL
                """, (str(DATA_RETENTION_DAYS),))
                results['sensor_readings'] = cur.rowcount
            
            # Cleanup climate readings
            if DATA_RETENTION_DAYS > 0:
                cur.execute("""
                    DELETE FROM climate_readings 
                    WHERE created_at < NOW() - (%s || ' days')::INTERVAL
                """, (str(DATA_RETENTION_DAYS),))
                results['climate_readings'] = cur.rowcount
            
            # Cleanup security events
            if SECURITY_RETENTION_DAYS > 0:
                cur.execute("""
                    DELETE FROM security_events 
                    WHERE created_at < NOW() - (%s || ' days')::INTERVAL
                """, (str(SECURITY_RETENTION_DAYS),))
                results['security_events'] = cur.rowcount
            
            # Cleanup audit log
            if AUDIT_RETENTION_DAYS > 0:
                cur.execute("""
                    DELETE FROM audit_log 
                    WHERE created_at < NOW() - (%s || ' days')::INTERVAL
                """, (str(AUDIT_RETENTION_DAYS),))
                results['audit_log'] = cur.rowcount
            
            # Cleanup request log (always 7 days)
            cur.execute("""
                DELETE FROM request_log 
                WHERE created_at < NOW() - INTERVAL '7 days'
            """)
            results['request_log'] = cur.rowcount
            
            conn.commit()
        
        total_deleted = sum(results.values())
        
        return jsonify({
            'success': True,
            'deleted': results,
            'total_deleted': total_deleted,
            'retention_settings': {
                'sensor_readings_days': DATA_RETENTION_DAYS,
                'security_events_days': SECURITY_RETENTION_DAYS,
                'audit_log_days': AUDIT_RETENTION_DAYS
            }
        })
        
    except Exception as e:
        logger.error(f"Cleanup failed: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/admin/stats', methods=['GET'])
@require_api_key_write
def get_database_stats():
    """Get database size and row count statistics."""
    try:
        with get_db() as conn:
            cur = conn.cursor()
            
            # Get table sizes and counts
            cur.execute("""
                SELECT 
                    relname as table_name,
                    n_live_tup as row_count,
                    pg_size_pretty(pg_total_relation_size(relid)) as total_size
                FROM pg_stat_user_tables
                ORDER BY pg_total_relation_size(relid) DESC
            """)
            tables = cur.fetchall()
            
            # Get oldest records
            oldest = {}
            for table in ['sensor_readings', 'climate_readings', 'security_events', 'audit_log', 'event_log']:
                try:
                    cur.execute(f"SELECT MIN(created_at) as oldest FROM {table}")
                    row = cur.fetchone()
                    if row and row['oldest']:
                        oldest[table] = row['oldest'].isoformat()
                except:
                    pass
        
        return jsonify({
            'tables': [dict(t) for t in tables],
            'oldest_records': oldest,
            'retention_settings': {
                'sensor_readings_days': DATA_RETENTION_DAYS,
                'security_events_days': SECURITY_RETENTION_DAYS,
                'audit_log_days': AUDIT_RETENTION_DAYS
            }
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == '__main__':
    print("""
═══════════════════════════════════════════════════════════════════════════════
   ClimaX Security System - Audit Logging Server v3.0
═══════════════════════════════════════════════════════════════════════════════
""")
    
    if not init_db_pool():
        print("\n⚠️  Warning: Database pool initialization failed!")
        print("   Check your .env configuration\n")
    elif not init_db():
        print("\n⚠️  Warning: Database connection failed!")
        print("   Run: psql -f database_schema.sql\n")
    
    # Determine auth status
    auth_status = []
    if API_KEY_WRITE:
        auth_status.append("Write")
    if API_KEY_READ:
        auth_status.append("Read")
    if API_KEY_LEGACY:
        auth_status.append("Legacy")
    auth_str = ", ".join(auth_status) if auth_status else "Disabled (dev mode)"
    
    print(f"""
Configuration:
   Database:  {DATABASE_URL.split('@')[1] if '@' in DATABASE_URL else 'configured'}
   API Keys:  {auth_str}
   Timezone:  {TIMEZONE}
   Host:      {HOST}:{PORT}
   Retention: {DATA_RETENTION_DAYS}d sensor, {SECURITY_RETENTION_DAYS}d security, {AUDIT_RETENTION_DAYS}d audit

Logging Endpoints (require write API key):
   POST /api/log/event         - Log any event
   POST /api/log/climate       - Log climate reading
   POST /api/log/battery       - Log battery reading
   POST /api/log/alarm         - Log alarm event
   POST /api/log/metrics       - Log system metrics
   POST /api/log/sensor-state  - Update sensor state

Query Endpoints (require read API key):
   GET  /api/events            - Query events
   GET  /api/climate/<mac>     - Climate history
   GET  /api/battery/<mac>     - Battery history
   GET  /api/alarms            - Alarm history
   GET  /api/sensors           - All sensors
   GET  /api/sensors/<mac>     - Sensor details
   GET  /api/stats/daily       - Daily statistics
   GET  /api/export/events     - Export CSV

Dashboard Endpoints (require read API key):
   GET  /api/dashboard/summary         - Quick overview
   GET  /api/dashboard/recent-activity - Activity feed
   GET  /api/dashboard/climate-current - Current readings

Admin Endpoints (require write API key):
   GET  /api/admin/retention   - View retention settings
   POST /api/admin/cleanup     - Trigger data cleanup
   GET  /api/admin/stats       - Database statistics

Public Endpoints:
   GET  /api/health            - Health check
   GET  /api/server/time       - Server time (for device sync)

Starting server...
═══════════════════════════════════════════════════════════════════════════════
""")
    
    app.run(host=HOST, port=PORT, debug=DEBUG)
