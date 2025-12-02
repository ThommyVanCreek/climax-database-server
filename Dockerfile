# ═══════════════════════════════════════════════════════════════════════════════
# ClimaX Database Server - Docker Image
# ═══════════════════════════════════════════════════════════════════════════════
# Build: docker build -t climax-api .
# Run:   docker run -p 5000:5000 --env-file .env climax-api
# ═══════════════════════════════════════════════════════════════════════════════

FROM python:3.11-slim

# Add labels for container registry
LABEL org.opencontainers.image.title="ClimaX API Server"
LABEL org.opencontainers.image.description="Flask REST API for ClimaX Security System"
LABEL org.opencontainers.image.vendor="ClimaX"

WORKDIR /app

# Install system dependencies for psycopg2
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY database_server.py .
COPY database_schema.sql .

# Create non-root user
RUN useradd -m -u 1000 -s /sbin/nologin climax && \
    chown -R climax:climax /app

USER climax

# Environment defaults (override via docker-compose or -e flags)
ENV HOST=0.0.0.0
ENV PORT=5000
ENV DEBUG=false
ENV WORKERS=2
ENV THREADS=4

EXPOSE 5000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:5000/api/health || exit 1

# Run with gunicorn for production
CMD gunicorn \
    --bind ${HOST}:${PORT} \
    --workers ${WORKERS} \
    --threads ${THREADS} \
    --timeout 120 \
    --access-logfile - \
    --error-logfile - \
    --capture-output \
    database_server:app
