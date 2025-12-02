#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ClimaX Server - Local Development Script
# ═══════════════════════════════════════════════════════════════════════════════
# Run the Flask server locally without Docker for faster development

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════════════════════════════════════════"
echo "  ClimaX Server - Local Development"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Check for virtual environment
if [ ! -d "venv" ]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv venv
fi

# Activate virtual environment
source venv/bin/activate

# Install dependencies
echo "📦 Installing dependencies..."
pip install -q -r requirements.txt

# Check for .env file
if [ ! -f ".env" ]; then
    echo "📋 Creating .env from template..."
    cp .env.example .env
    echo "⚠️  Please edit .env with your configuration!"
    echo "   Then run this script again."
    exit 1
fi

# Load environment
export $(grep -v '^#' .env | xargs)

echo ""
echo "🔧 Configuration:"
echo "   Database: ${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-climax}"
echo "   Port:     ${PORT:-5000}"
echo "   Debug:    ${DEBUG:-false}"
echo ""

# Check database connection
echo "🔍 Checking database connection..."
if python3 -c "import psycopg2; psycopg2.connect(host='${DB_HOST:-localhost}', port=${DB_PORT:-5432}, dbname='${DB_NAME:-climax}', user='${DB_USER:-climax}', password='${DB_PASSWORD}')" 2>/dev/null; then
    echo "   ✅ Database connected"
else
    echo "   ⚠️  Database not reachable (start PostgreSQL first)"
    echo ""
    echo "   Quick start with Docker:"
    echo "   docker run -d --name climax-db-dev -p 5432:5432 \\"
    echo "     -e POSTGRES_DB=climax -e POSTGRES_USER=climax -e POSTGRES_PASSWORD=devpassword \\"
    echo "     postgres:16-alpine"
    echo ""
fi

echo ""
echo "🚀 Starting server..."
echo "   API:  http://localhost:${PORT:-5000}"
echo "   Docs: http://localhost:${PORT:-5000}/api/health"
echo ""

# Run the server
python3 database_server.py
