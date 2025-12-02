#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════════
# ClimaX - LXC Container Setup Script (Alpine Linux)
# Run this INSIDE the LXC container after creation
# 
# Usage:
#   ./lxc-setup.sh          # Normal installation
#   ./lxc-setup.sh --reset  # Reset/clean everything for fresh install
#
# Prerequisites:
#   1. Copy server folder to LXC: scp -r ./server/* root@<lxc-ip>:/root/
#   2. Edit /root/.env with your passwords/API keys
#   3. Run this script
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
APP_DIR="/opt/climax"
API_PORT="5000"

# ─────────────────────────────────────────────────────────────────────────────
# Colors for output
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# Handle --reset flag
# ─────────────────────────────────────────────────────────────────────────────
if [ "$1" = "--reset" ]; then
    echo "${YELLOW}"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "   RESET MODE - Cleaning everything"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "${NC}"
    
    echo "${YELLOW}Stopping services...${NC}"
    rc-service climax-api stop 2>/dev/null || true
    rc-service postgresql stop 2>/dev/null || true
    
    echo "${YELLOW}Removing climax-api service...${NC}"
    rc-update del climax-api default 2>/dev/null || true
    rm -f /etc/init.d/climax-api
    
    echo "${YELLOW}Removing application directory...${NC}"
    rm -rf "$APP_DIR"
    
    echo "${YELLOW}Dropping database and users...${NC}"
    rc-service postgresql start 2>/dev/null || true
    sleep 2
    su postgres -c "psql -c 'DROP DATABASE IF EXISTS climax;'" 2>/dev/null || true
    su postgres -c "psql -c 'DROP USER IF EXISTS climax;'" 2>/dev/null || true
    su postgres -c "psql -c 'DROP USER IF EXISTS climax_dashboard;'" 2>/dev/null || true
    
    echo "${YELLOW}Removing PostgreSQL data (complete reset)...${NC}"
    rc-service postgresql stop 2>/dev/null || true
    rm -rf /var/lib/postgresql/data
    
    echo "${GREEN}✓ Reset complete. Run script again without --reset to install fresh.${NC}"
    exit 0
fi

echo "${GREEN}"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "   ClimaX - LXC Setup (Alpine Linux)"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Check if running as root
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}Please run as root${NC}"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check for .env file
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "/root/.env" ]; then
    echo "${RED}Error: /root/.env file not found!${NC}"
    echo "Please copy the server folder to /root/ including the .env file."
    exit 1
fi

# Load configuration from .env
echo "${YELLOW}Loading configuration from .env...${NC}"
DB_NAME=$(grep "^DB_NAME=" /root/.env | cut -d'=' -f2)
DB_USER=$(grep "^DB_USER=" /root/.env | cut -d'=' -f2)
DB_PASSWORD=$(grep "^DB_PASSWORD=" /root/.env | cut -d'=' -f2)
DB_DASHBOARD_USER=$(grep "^DB_DASHBOARD_USER=" /root/.env | cut -d'=' -f2)
DB_DASHBOARD_PASSWORD=$(grep "^DB_DASHBOARD_PASSWORD=" /root/.env | cut -d'=' -f2)
API_KEY_WRITE=$(grep "^API_KEY_WRITE=" /root/.env | cut -d'=' -f2)
API_KEY_READ=$(grep "^API_KEY_READ=" /root/.env | cut -d'=' -f2)
TIMEZONE=$(grep "^TIMEZONE=" /root/.env | cut -d'=' -f2)
DATA_RETENTION_DAYS=$(grep "^DATA_RETENTION_DAYS=" /root/.env | cut -d'=' -f2)
SECURITY_RETENTION_DAYS=$(grep "^SECURITY_RETENTION_DAYS=" /root/.env | cut -d'=' -f2)
AUDIT_RETENTION_DAYS=$(grep "^AUDIT_RETENTION_DAYS=" /root/.env | cut -d'=' -f2)
CLEANUP_SCHEDULE=$(grep "^CLEANUP_SCHEDULE=" /root/.env | cut -d'=' -f2-)

# Defaults if not set
DB_NAME=${DB_NAME:-climax}
DB_USER=${DB_USER:-climax}
DB_DASHBOARD_USER=${DB_DASHBOARD_USER:-climax_dashboard}
TIMEZONE=${TIMEZONE:-Europe/Berlin}
DATA_RETENTION_DAYS=${DATA_RETENTION_DAYS:-365}
SECURITY_RETENTION_DAYS=${SECURITY_RETENTION_DAYS:-730}
AUDIT_RETENTION_DAYS=${AUDIT_RETENTION_DAYS:-365}
CLEANUP_SCHEDULE=${CLEANUP_SCHEDULE:-"0 3 * * *"}

# Track if we generated any credentials (for logging)
GENERATED_CREDS=""

# Auto-generate DB_PASSWORD if empty
if [ -z "$DB_PASSWORD" ]; then
    echo "${YELLOW}Generating DB_PASSWORD...${NC}"
    DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" /root/.env
    GENERATED_CREDS="${GENERATED_CREDS}\n  DB_PASSWORD=${DB_PASSWORD}"
fi

# Auto-generate DB_DASHBOARD_PASSWORD if empty
if [ -z "$DB_DASHBOARD_PASSWORD" ]; then
    echo "${YELLOW}Generating DB_DASHBOARD_PASSWORD...${NC}"
    DB_DASHBOARD_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
    sed -i "s/^DB_DASHBOARD_PASSWORD=.*/DB_DASHBOARD_PASSWORD=${DB_DASHBOARD_PASSWORD}/" /root/.env
    GENERATED_CREDS="${GENERATED_CREDS}\n  DB_DASHBOARD_PASSWORD=${DB_DASHBOARD_PASSWORD}"
fi

# Auto-generate API_KEY_WRITE if empty
if [ -z "$API_KEY_WRITE" ]; then
    echo "${YELLOW}Generating API_KEY_WRITE...${NC}"
    API_KEY_WRITE=$(openssl rand -hex 32)
    sed -i "s/^API_KEY_WRITE=.*/API_KEY_WRITE=${API_KEY_WRITE}/" /root/.env
    GENERATED_CREDS="${GENERATED_CREDS}\n  API_KEY_WRITE=${API_KEY_WRITE}"
fi

# Auto-generate API_KEY_READ if empty
if [ -z "$API_KEY_READ" ]; then
    echo "${YELLOW}Generating API_KEY_READ...${NC}"
    API_KEY_READ=$(openssl rand -hex 32)
    sed -i "s/^API_KEY_READ=.*/API_KEY_READ=${API_KEY_READ}/" /root/.env
    GENERATED_CREDS="${GENERATED_CREDS}\n  API_KEY_READ=${API_KEY_READ}"
fi

# Log generated credentials
if [ -n "$GENERATED_CREDS" ]; then
    echo ""
    echo "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo "${GREEN}   AUTO-GENERATED CREDENTIALS (save these!)${NC}"
    echo "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "$GENERATED_CREDS"
    echo "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Also save to a credentials file
    echo "# ClimaX Generated Credentials - $(date)" > /root/climax-credentials.txt
    echo "# SAVE THIS FILE SECURELY AND DELETE AFTER CONFIGURING ESP32" >> /root/climax-credentials.txt
    echo -e "$GENERATED_CREDS" >> /root/climax-credentials.txt
    chmod 600 /root/climax-credentials.txt
    echo "${YELLOW}Credentials also saved to: /root/climax-credentials.txt${NC}"
    echo ""
fi

echo "${GREEN}✓ Configuration loaded${NC}"
echo "  Data retention: ${DATA_RETENTION_DAYS} days (sensor), ${SECURITY_RETENTION_DAYS} days (security), ${AUDIT_RETENTION_DAYS} days (audit)"

# ─────────────────────────────────────────────────────────────────────────────
# [1/8] Update system
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[1/8] Updating system...${NC}"
apk update && apk upgrade || {
    echo "${RED}Error: Failed to update system${NC}"
    exit 1
}
echo "${GREEN}✓ System updated${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [2/8] Set timezone
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[2/8] Setting timezone to ${TIMEZONE}...${NC}"
apk add tzdata
cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
echo "${GREEN}✓ Timezone set${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [3/8] Install PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[3/8] Installing PostgreSQL...${NC}"
apk add postgresql postgresql-contrib postgresql-client || {
    echo "${RED}Error: Failed to install PostgreSQL${NC}"
    exit 1
}

# Initialize PostgreSQL if not already done
if [ ! -d "/var/lib/postgresql/data" ] || [ -z "$(ls -A /var/lib/postgresql/data 2>/dev/null)" ]; then
    mkdir -p /var/lib/postgresql/data
    chown -R postgres:postgres /var/lib/postgresql
    su postgres -c "initdb -D /var/lib/postgresql/data"
fi

# Start PostgreSQL
rc-update add postgresql default 2>/dev/null || true
rc-service postgresql start || {
    echo "${RED}Error: Failed to start PostgreSQL${NC}"
    exit 1
}
echo "${GREEN}✓ PostgreSQL installed and started${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [4/8] Install Python and dependencies
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[4/8] Installing Python...${NC}"
apk add python3 py3-pip py3-virtualenv openssl curl || {
    echo "${RED}Error: Failed to install Python${NC}"
    exit 1
}
echo "${GREEN}✓ Python installed${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [5/8] Create database and users
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[5/8] Setting up database...${NC}"

# Wait for PostgreSQL to be ready
sleep 2

su postgres -c "psql" <<EOF
-- Set timezone
ALTER SYSTEM SET timezone = '${TIMEZONE}';

-- Create main application user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
    END IF;
END
\$\$;

-- Create dashboard read-only user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_DASHBOARD_USER}') THEN
        CREATE USER ${DB_DASHBOARD_USER} WITH PASSWORD '${DB_DASHBOARD_PASSWORD}';
    END IF;
END
\$\$;

-- Create database if not exists
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')
\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_DASHBOARD_USER};
EOF

# Grant schema privileges
su postgres -c "psql -d ${DB_NAME}" <<EOF
-- Main user privileges
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};

-- Dashboard user (read-only)
GRANT USAGE ON SCHEMA public TO ${DB_DASHBOARD_USER};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${DB_DASHBOARD_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${DB_DASHBOARD_USER};
EOF

# Reload to apply timezone
rc-service postgresql restart

echo "${GREEN}✓ Database configured with main and dashboard users${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [6/8] Configure PostgreSQL for network access
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[6/8] Configuring PostgreSQL network access...${NC}"

PG_DATA="/var/lib/postgresql/data"
PG_HBA="${PG_DATA}/pg_hba.conf"
PG_CONF="${PG_DATA}/postgresql.conf"

# Backup original files
cp "$PG_HBA" "${PG_HBA}.bak"
cp "$PG_CONF" "${PG_CONF}.bak"

# Configure listening address
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"

# Add network access rules (if not already present)
if ! grep -q "# ClimaX network access" "$PG_HBA"; then
    cat >> "$PG_HBA" <<EOF

# ClimaX network access
host    ${DB_NAME}    ${DB_USER}            172.22.0.0/24    scram-sha-256
host    ${DB_NAME}    ${DB_USER}            10.0.0.0/8       scram-sha-256
host    ${DB_NAME}    ${DB_DASHBOARD_USER}  172.22.0.0/24    scram-sha-256
host    ${DB_NAME}    ${DB_DASHBOARD_USER}  10.0.0.0/8       scram-sha-256
host    ${DB_NAME}    ${DB_DASHBOARD_USER}  0.0.0.0/0        scram-sha-256
host    all           all                   0.0.0.0/0        scram-sha-256
EOF
fi

rc-service postgresql restart
echo "${GREEN}✓ PostgreSQL network access configured${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [7/8] Setup application directory
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[7/8] Setting up application...${NC}"

mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Copy files from /root
if [ -f "/root/database_server.py" ]; then
    cp /root/database_server.py "$APP_DIR/server.py"
    echo "  Copied database_server.py -> server.py"
fi
if [ -f "/root/database_schema.sql" ]; then
    cp /root/database_schema.sql "$APP_DIR/schema.sql"
    echo "  Copied database_schema.sql -> schema.sql"
fi
if [ -f "/root/requirements.txt" ]; then
    cp /root/requirements.txt "$APP_DIR/requirements.txt"
    echo "  Copied requirements.txt"
fi
if [ -f "/root/.env" ]; then
    cp /root/.env "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
    echo "  Copied .env (permissions: 600)"
fi

# Create Python virtual environment
if [ ! -d "venv" ]; then
    python3 -m venv venv || {
        echo "${RED}Error: Failed to create Python virtual environment${NC}"
        exit 1
    }
fi

# Activate venv and install dependencies
. venv/bin/activate

pip install --upgrade pip

# Install from requirements.txt if it exists, otherwise install defaults
if [ -f "$APP_DIR/requirements.txt" ]; then
    pip install -r "$APP_DIR/requirements.txt" || {
        echo "${RED}Error: Failed to install Python dependencies${NC}"
        exit 1
    }
else
    pip install flask psycopg2-binary python-dotenv gunicorn pytz || {
        echo "${RED}Error: Failed to install Python dependencies${NC}"
        exit 1
    }
fi

echo "${GREEN}✓ Application setup complete${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# [8/8] Create OpenRC service
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}[8/8] Creating OpenRC service...${NC}"

# Create startup wrapper script
cat > "${APP_DIR}/start.sh" <<'STARTEOF'
#!/bin/sh
cd /opt/climax
. ./venv/bin/activate
exec ./venv/bin/gunicorn -w 2 -b 0.0.0.0:5000 server:app
STARTEOF
chmod +x "${APP_DIR}/start.sh"

# Create OpenRC service
cat > /etc/init.d/climax-api <<'INITEOF'
#!/sbin/openrc-run

name="ClimaX API Server"
description="ClimaX Climate Monitoring API"

command="/opt/climax/start.sh"
command_background=true
pidfile="/run/climax-api.pid"
directory="/opt/climax"

depend() {
    need net postgresql
    after postgresql
}
INITEOF

chmod +x /etc/init.d/climax-api
rc-update add climax-api default
echo "${GREEN}✓ OpenRC service created${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Load database schema if available
# ─────────────────────────────────────────────────────────────────────────────
if [ -f "${APP_DIR}/schema.sql" ]; then
    echo "${YELLOW}Loading database schema...${NC}"
    su postgres -c "psql -d ${DB_NAME} -f ${APP_DIR}/schema.sql" && \
        echo "${GREEN}✓ Schema loaded${NC}" || \
        echo "${YELLOW}Warning: Could not load schema. Load it manually later.${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Setup data retention cleanup cron job
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}Setting up data retention cleanup...${NC}"

# Create cleanup script
cat > "${APP_DIR}/cleanup.sh" <<CLEANUPEOF
#!/bin/sh
# ClimaX Data Retention Cleanup Script
# Runs via cron to delete old data based on retention settings

# Load environment
if [ -f "${APP_DIR}/.env" ]; then
    export \$(grep -v '^#' ${APP_DIR}/.env | xargs)
fi

# Defaults
DATA_DAYS=\${DATA_RETENTION_DAYS:-365}
SECURITY_DAYS=\${SECURITY_RETENTION_DAYS:-730}
AUDIT_DAYS=\${AUDIT_RETENTION_DAYS:-365}

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> /var/log/climax-cleanup.log
}

log "Starting cleanup..."

# Cleanup sensor readings
if [ "\$DATA_DAYS" -gt 0 ]; then
    DELETED=\$(su postgres -c "psql -d ${DB_NAME} -t -c \"DELETE FROM sensor_readings WHERE created_at < NOW() - INTERVAL '\${DATA_DAYS} days'; SELECT COUNT(*);\"" 2>/dev/null | tr -d ' ')
    log "Deleted \${DELETED:-0} sensor readings older than \${DATA_DAYS} days"
fi

# Cleanup security events
if [ "\$SECURITY_DAYS" -gt 0 ]; then
    DELETED=\$(su postgres -c "psql -d ${DB_NAME} -t -c \"DELETE FROM security_events WHERE created_at < NOW() - INTERVAL '\${SECURITY_DAYS} days'; SELECT COUNT(*);\"" 2>/dev/null | tr -d ' ')
    log "Deleted \${DELETED:-0} security events older than \${SECURITY_DAYS} days"
fi

# Cleanup audit logs
if [ "\$AUDIT_DAYS" -gt 0 ]; then
    DELETED=\$(su postgres -c "psql -d ${DB_NAME} -t -c \"DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL '\${AUDIT_DAYS} days'; SELECT COUNT(*);\"" 2>/dev/null | tr -d ' ')
    log "Deleted \${DELETED:-0} audit log entries older than \${AUDIT_DAYS} days"
fi

# Cleanup request logs (same as audit)
if [ "\$AUDIT_DAYS" -gt 0 ]; then
    DELETED=\$(su postgres -c "psql -d ${DB_NAME} -t -c \"DELETE FROM request_log WHERE created_at < NOW() - INTERVAL '\${AUDIT_DAYS} days'; SELECT COUNT(*);\"" 2>/dev/null | tr -d ' ')
    log "Deleted \${DELETED:-0} request log entries older than \${AUDIT_DAYS} days"
fi

log "Cleanup complete"
CLEANUPEOF

chmod +x "${APP_DIR}/cleanup.sh"

# Setup cron job if schedule is configured
if [ -n "$CLEANUP_SCHEDULE" ]; then
    # Install dcron if not present
    apk add dcron 2>/dev/null || true
    rc-update add dcron default 2>/dev/null || true
    rc-service dcron start 2>/dev/null || true
    
    # Add cron job
    CRON_LINE="${CLEANUP_SCHEDULE} ${APP_DIR}/cleanup.sh"
    (crontab -l 2>/dev/null | grep -v "climax.*cleanup" ; echo "$CRON_LINE") | crontab -
    echo "${GREEN}✓ Data cleanup scheduled: ${CLEANUP_SCHEDULE}${NC}"
else
    echo "${YELLOW}  Cleanup schedule not set, skipping cron setup${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Start the service
# ─────────────────────────────────────────────────────────────────────────────
echo "${YELLOW}Starting ClimaX API service...${NC}"
rc-service climax-api start && \
    echo "${GREEN}✓ Service started${NC}" || \
    echo "${YELLOW}Warning: Could not start service. Check logs with: tail -f /var/log/messages${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Print summary
# ─────────────────────────────────────────────────────────────────────────────
CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}' || ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

echo ""
echo "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo "${GREEN}   Setup Complete!${NC}"
echo "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Service management:"
echo "   rc-service climax-api status"
echo "   rc-service climax-api restart"
echo "   tail -f /var/log/messages"
echo ""
echo "─────────────────────────────────────────────────────────────────────────────"
echo "ESP32 Configuration (config/database.h):"
echo "   #define DB_API_HOST \"${CONTAINER_IP}\""
echo "   #define DB_API_PORT ${API_PORT}"
echo "   #define DB_API_KEY \"${API_KEY_WRITE}\""
echo "─────────────────────────────────────────────────────────────────────────────"
echo ""
echo "API Endpoints:"
echo "   Health:    curl http://${CONTAINER_IP}:${API_PORT}/api/health"
echo "   Insert:    curl -X POST -H 'X-API-Key: ${API_KEY_WRITE}' http://${CONTAINER_IP}:${API_PORT}/api/sensor-readings"
echo "   Summary:   curl -H 'X-API-Key: ${API_KEY_READ}' http://${CONTAINER_IP}:${API_PORT}/api/dashboard/summary"
echo ""
echo "─────────────────────────────────────────────────────────────────────────────"
echo "Dashboard Database Access (Grafana/Adminer):"
echo "   Host:      ${CONTAINER_IP}"
echo "   Port:      5432"
echo "   Database:  ${DB_NAME}"
echo "   User:      ${DB_DASHBOARD_USER} (read-only)"
echo "   Password:  ${DB_DASHBOARD_PASSWORD}"
echo "─────────────────────────────────────────────────────────────────────────────"
echo ""
echo "Data Retention:"
echo "   Sensor readings: ${DATA_RETENTION_DAYS} days"
echo "   Security events: ${SECURITY_RETENTION_DAYS} days"
echo "   Audit logs:      ${AUDIT_RETENTION_DAYS} days"
echo "   Cleanup runs:    ${CLEANUP_SCHEDULE}"
echo "─────────────────────────────────────────────────────────────────────────────"
echo ""
echo "${YELLOW}All credentials saved in: ${APP_DIR}/.env${NC}"
if [ -f "/root/climax-credentials.txt" ]; then
    echo "${YELLOW}Generated credentials saved in: /root/climax-credentials.txt${NC}"
fi
echo ""
