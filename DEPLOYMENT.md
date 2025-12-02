# Deployment Guide

## Version 3.0 Updates

- **Enhanced Security**: Separate read/write API keys
- **Dashboard Support**: Read-only database user for Grafana/dashboards
- **Local Timestamps**: Accurate timezone-aware timestamps from devices
- **Connection Pooling**: Better performance under load

## Prerequisites

- Proxmox 7.x+ or Docker environment
- Alpine 3.16 template (for LXC)
- Network access to 172.22.0.220 (or your chosen IP)

## Quick Start (Docker)

```bash
# 1. Copy and configure environment
cp .env.template .env

# 2. Generate secure API keys
python3 -c "import secrets; print('API_KEY_WRITE=' + secrets.token_urlsafe(32))"
python3 -c "import secrets; print('API_KEY_READ=' + secrets.token_urlsafe(32))"

# 3. Edit .env with generated keys and your database password
nano .env

# 4. Start all services
docker-compose up -d

# 5. Start with dashboard (Grafana + Adminer)
docker-compose --profile admin --profile dashboard up -d

# 6. Verify
curl http://localhost:5000/api/health
```

## Deployment Methods

### 1. Proxmox LXC (Recommended)

**On Proxmox Host:**

```bash
# Download and run
chmod +x proxmox-create-lxc.sh
./proxmox-create-lxc.sh

# You'll be prompted for:
# - Root password (min 8 chars)
# - Container will be created at 172.22.0.220/24
```

**Inside Container (after creation):**

```bash
# SSH into container
ssh root@172.22.0.220

# Run setup
chmod +x /root/lxc-setup.sh
./lxc-setup.sh

# Script will:
# ✓ Update Alpine packages
# ✓ Install PostgreSQL 17
# ✓ Create database and user
# ✓ Auto-generate API keys
# ✓ Setup systemd service
# ✓ Create dashboard read-only user
```

**Retrieve API Keys:**
```bash
# Write key (for ESP32)
grep API_KEY_WRITE /opt/climax/.env | cut -d'=' -f2

# Read key (for dashboards)
grep API_KEY_READ /opt/climax/.env | cut -d'=' -f2
```

### 2. Docker Compose

```bash
# Create .env file
cp .env.template .env
# Edit .env with your credentials

# Start core services (postgres + api)
docker-compose up -d

# Start with admin tools
docker-compose --profile admin up -d

# Start with dashboards
docker-compose --profile dashboard up -d

# Verify
curl http://localhost:5000/api/health
```

### 3. Manual Installation

```bash
# Install dependencies
sudo apt install postgresql python3 python3-pip
pip install -r requirements.txt

# Setup database
createdb -U postgres climax
psql -U postgres -d climax -f database_schema.sql

# Create .env
cp .env.template .env
# Edit with your values

# Run
python database_server.py
```

## Security Configuration

### API Keys

The system uses two separate API keys:

1. **API_KEY_WRITE** - Required for ESP32/sensors to write data
   - Used for all POST endpoints
   - Keep this secure and only on your devices

2. **API_KEY_READ** - Required for dashboards to read data
   - Used for all GET endpoints
   - Safe to use in web dashboards

3. **API_KEY** (legacy) - Works for both read and write
   - For backwards compatibility
   - Consider migrating to separate keys

### Database Users

1. **climax** (main user) - Full read/write access
   - Used by the API server
   - Password in DB_PASSWORD

2. **climax_dashboard** - Read-only access
   - Safe for Grafana, Adminer, or direct DB access
   - Password in DB_DASHBOARD_PASSWORD

### Setting Up Dashboard User

```sql
-- Run this in PostgreSQL to change the dashboard password
ALTER USER climax_dashboard WITH PASSWORD 'YourSecureDashboardPassword';

-- Verify permissions (should only show SELECT)
\dp
```

## Bridge Configuration

After backend is running:

1. Get API_KEY_WRITE from container:
   ```bash
   ssh root@172.22.0.220 'grep API_KEY_WRITE /opt/climax/.env | cut -d= -f2'
   ```

2. Update Bridge code in `ClimaX_Bridge/src/config/database.h`:
   ```cpp
   #define DB_LOGGING_ENABLED    true
   #define DB_API_HOST           "172.22.0.220"
   #define DB_API_PORT           5000
   #define DB_API_KEY            "YOUR_WRITE_API_KEY_HERE"
   ```

3. For accurate timestamps, ensure ESP32 has NTP synced and sends `device_time`:
   ```cpp
   // In your logging code
   doc["device_time"] = getISOTimestamp();  // "2024-01-15T10:30:00+01:00"
   ```

4. Recompile and deploy Bridge

## Dashboard Setup

### Grafana Configuration

1. Start Grafana:
   ```bash
   docker-compose --profile dashboard up -d
   ```

2. Access at http://localhost:3000 (admin/admin)

3. Add PostgreSQL Data Source:
   - Host: `postgres:5432`
   - Database: `climax`
   - User: `climax_dashboard`
   - Password: (from DB_DASHBOARD_PASSWORD)
   - SSL Mode: disable

4. Import dashboards or create queries:
   ```sql
   -- Example: Temperature over time
   SELECT local_time, sensor_name, temperature 
   FROM climate_readings 
   WHERE local_time > NOW() - INTERVAL '24 hours'
   ORDER BY local_time;
   ```

### Adminer Access

1. Start Adminer:
   ```bash
   docker-compose --profile admin up -d
   ```

2. Access at http://localhost:8080

3. Login with dashboard user for read-only access

## Verification

```bash
# Health check
curl http://172.22.0.220:5000/api/health

# Expected response:
# {
#   "status": "healthy",
#   "database": "connected",
#   "timezone": "Europe/Berlin",
#   "total_events": 0,
#   "total_sensors": 0,
#   "sensors_online": 0,
#   "server_time": "2024-01-15T10:30:00+01:00"
# }

# Test with API key
curl -H "X-API-Key: YOUR_READ_KEY" http://172.22.0.220:5000/api/sensors

# Get server time (useful for ESP32 sync)
curl http://172.22.0.220:5000/api/server/time

# Dashboard summary
curl -H "X-API-Key: YOUR_READ_KEY" http://172.22.0.220:5000/api/dashboard/summary

# Check service status
ssh root@172.22.0.220 'systemctl status climax-api'

# View logs
ssh root@172.22.0.220 'journalctl -u climax-api -f'
```

## Troubleshooting

**Database connection error:**
```bash
# Verify PostgreSQL is running
ssh root@172.22.0.220 'systemctl status postgresql'

# Test connection
psql -U climax -h 172.22.0.220 -d climax -c "SELECT 1"

# Check timezone setting
psql -U climax -d climax -c "SHOW timezone;"
```

**API not responding:**
```bash
# Check if service is running
ssh root@172.22.0.220 'systemctl status climax-api'

# Restart service
ssh root@172.22.0.220 'systemctl restart climax-api'

# View logs
ssh root@172.22.0.220 'journalctl -u climax-api -n 50'
```

**Authentication errors:**
```bash
# Verify API keys are set
grep "API_KEY" /opt/climax/.env

# Test with correct header
curl -v -H "X-API-Key: your-key-here" http://localhost:5000/api/sensors
```

**Timestamp issues:**
```bash
# Check server timezone
curl http://localhost:5000/api/server/time

# Verify database timezone
psql -U climax -d climax -c "SELECT NOW(), NOW() AT TIME ZONE 'Europe/Berlin';"
```

**Container won't start:**
```bash
# Check Proxmox status
pct status 22220

# Start container
pct start 22220

# Access console
pct enter 22220
```

## Data Retention

The database automatically includes functions for data cleanup:

```sql
-- Clean up data older than 90 days (default)
SELECT cleanup_old_data(90);

-- Custom retention
SELECT cleanup_old_data(30);  -- Keep only 30 days
```

Set up a cron job for automatic cleanup:

```bash
# Add to crontab
0 2 * * 0 psql -U climax -d climax -c "SELECT cleanup_old_data(90);"
```
