#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# ClimaX Server Deployment Script
# Deploys server files to Proxmox LXC container and restarts the service
# ═══════════════════════════════════════════════════════════════════════════

set -e

# Configuration
PROXMOX_HOST="root@172.22.0.205"
PROXMOX_TMP="/mnt/server"
LXC_ID="22220"
LXC_PATH="/opt/climax"
LOCAL_SERVER_DIR="$(dirname "$0")"
SERVER_IP="172.22.0.220"
SERVER_PORT="5000"

# Files to deploy
FILES="database_server.py database_schema.sql requirements.txt .env"

echo "═══════════════════════════════════════════════════════════════════════════"
echo "  ClimaX Server Deployment"
echo "═══════════════════════════════════════════════════════════════════════════"

# Step 1: Check local files exist
echo ""
echo "🔍 Step 1: Checking local files..."
for file in $FILES; do
    if [ ! -f "$LOCAL_SERVER_DIR/$file" ]; then
        echo "❌ Error: $file not found in $LOCAL_SERVER_DIR"
        exit 1
    fi
    echo "   ✓ $file"
done
echo "✅ All files found"

# Step 2: Clean up old files on Proxmox host
echo ""
echo "🧹 Step 2: Cleaning up old files on Proxmox..."
ssh "$PROXMOX_HOST" "rm -f $PROXMOX_TMP/database_server.py $PROXMOX_TMP/database_schema.sql $PROXMOX_TMP/requirements.txt $PROXMOX_TMP/.env"
echo "✅ Old files removed"

# Step 3: Copy files to Proxmox host
echo ""
echo "📦 Step 3: Copying files to Proxmox host..."
for file in $FILES; do
    scp "$LOCAL_SERVER_DIR/$file" "$PROXMOX_HOST:$PROXMOX_TMP/"
done
echo "✅ Files copied to Proxmox"

# Step 4: Stop the running server
echo ""
echo "🛑 Step 4: Stopping current server..."

# Kill by process name
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- pkill -9 -f 'python.*database_server' || true"
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- pkill -9 -f 'database_server.py' || true"

# Also kill anything on port 5000
PORT_PID=$(ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- fuser 5000/tcp 2>/dev/null || true")
if [ -n "$PORT_PID" ]; then
    echo "   Found process on port 5000: $PORT_PID"
    ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- fuser -k 5000/tcp || true"
fi

sleep 3

# Double-check nothing is on port 5000
PORT_CHECK=$(ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- fuser 5000/tcp 2>/dev/null || true")
if [ -n "$PORT_CHECK" ]; then
    echo "   ⚠️  Port 5000 still in use, force killing..."
    ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- fuser -k -9 5000/tcp || true"
    sleep 2
fi
echo "✅ Server stopped"

# Step 5: Clean and push files into LXC container
echo ""
echo "📦 Step 5: Pushing files into LXC container $LXC_ID..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- rm -f $LXC_PATH/database_server.py $LXC_PATH/database_schema.sql $LXC_PATH/requirements.txt $LXC_PATH/.env"
for file in $FILES; do
    ssh "$PROXMOX_HOST" "pct push $LXC_ID $PROXMOX_TMP/$file $LXC_PATH/$file"
done
echo "✅ Files pushed to container"

# Step 6: Install dependencies
echo ""
echo "📦 Step 6: Installing dependencies..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- $LXC_PATH/venv/bin/pip install -q -r $LXC_PATH/requirements.txt"
echo "✅ Dependencies installed"

# Step 6b: Clean public schema (remove old tables)
echo ""
echo "🧹 Step 6b: Cleaning public schema..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U climax -d climax -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO climax;'" 2>&1 | grep -v "^$" || true
echo "✅ Public schema cleaned"

# Step 6c: Drop and recreate climax schema for fresh start
echo ""
echo "🗄️  Step 6c: Recreating climax schema..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U climax -d climax -c 'DROP SCHEMA IF EXISTS climax CASCADE; CREATE SCHEMA climax;'" 2>&1 || true
echo "✅ Climax schema recreated"

# Step 6d: Apply database schema
echo ""
echo "🗄️  Step 6d: Applying database schema..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U climax -d climax -f $LXC_PATH/database_schema.sql" 2>&1 | tail -30
echo "✅ Database schema applied"

# Step 6e: Grant permissions and ownership to climax user
echo ""
echo "🔐 Step 6e: Setting ownership and permissions..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U postgres -d climax -c 'ALTER SCHEMA climax OWNER TO climax;'" 2>&1 | grep -v "^$" || true
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U postgres -d climax -c 'ALTER USER climax SET search_path TO climax; ALTER DATABASE climax SET search_path TO climax;'" 2>&1 | grep -v "^$" || true
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U postgres -d climax -c \"DO \\\$\\\$ DECLARE r RECORD; BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'climax' LOOP EXECUTE 'ALTER TABLE climax.' || quote_ident(r.tablename) || ' OWNER TO climax'; END LOOP; END \\\$\\\$;\"" 2>&1 | grep -v "^$" || true
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U postgres -d climax -c \"DO \\\$\\\$ DECLARE r RECORD; BEGIN FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'climax' LOOP EXECUTE 'ALTER SEQUENCE climax.' || quote_ident(r.sequence_name) || ' OWNER TO climax'; END LOOP; END \\\$\\\$;\"" 2>&1 | grep -v "^$" || true
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- psql -U postgres -d climax -c \"DO \\\$\\\$ DECLARE r RECORD; BEGIN FOR r IN SELECT viewname FROM pg_views WHERE schemaname = 'climax' LOOP EXECUTE 'ALTER VIEW climax.' || quote_ident(r.viewname) || ' OWNER TO climax'; END LOOP; END \\\$\\\$;\"" 2>&1 | grep -v "^$" || true
echo "✅ Ownership and permissions set"

# Step 6f: Ensure Adminer is installed and restart it
echo ""
echo "🔄 Step 6f: Restarting Adminer..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- pkill -f 'php.*8080' || true"
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- test -f /opt/adminer/index.php || wget -q -O /opt/adminer/index.php https://github.com/vrana/adminer/releases/download/v4.8.1/adminer-4.8.1.php"
# Start PHP server in background using nohup
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- nohup php -S 0.0.0.0:8080 -t /opt/adminer > /var/log/adminer.log 2>&1 &"
sleep 2
echo "✅ Adminer restarted on port 8080"

# Step 7: Start the server
echo ""
echo "🚀 Step 7: Starting server..."
ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- $LXC_PATH/venv/bin/python $LXC_PATH/database_server.py &" &
sleep 4
echo "✅ Server start command sent"

# Step 8: Verify server is running
echo ""
echo "🔍 Step 8: Verifying server is running..."
PROCESS_CHECK=$(ssh "$PROXMOX_HOST" "pct exec $LXC_ID -- pgrep -f database_server" 2>/dev/null || echo "")
if [ -n "$PROCESS_CHECK" ]; then
    echo "✅ Server process running (PID: $PROCESS_CHECK)"
else
    echo "⚠️  Server process not found - checking logs..."
fi

# Step 9: Test API endpoint
echo ""
echo "🔍 Step 9: Testing API endpoint..."
sleep 2
if curl -s --connect-timeout 5 "http://$SERVER_IP:$SERVER_PORT/api/health" > /dev/null 2>&1; then
    echo "✅ API is responding at http://$SERVER_IP:$SERVER_PORT"
else
    echo "⚠️  API not responding yet (may still be starting up)"
    echo "   Try: curl http://$SERVER_IP:$SERVER_PORT/api/health"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Deployment complete!"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "Useful commands:"
echo "  Check process: ssh $PROXMOX_HOST \"pct exec $LXC_ID -- ps aux | grep database_server\""
echo "  View logs:     ssh $PROXMOX_HOST \"pct exec $LXC_ID -- cat /opt/climax/server.log\""
echo "  Test API:      curl http://$SERVER_IP:$SERVER_PORT/api/health"
echo ""
