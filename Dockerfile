# ═══════════════════════════════════════════════════════════════════════════════
# ClimaX Database Server - Docker Image
# ═══════════════════════════════════════════════════════════════════════════════
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY database_server.py .
COPY database_schema.sql .

# Create non-root user
RUN useradd -m -u 1000 climax && chown -R climax:climax /app
USER climax

# Environment defaults
ENV HOST=0.0.0.0
ENV PORT=5000
ENV DEBUG=false

EXPOSE 5000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/api/health')" || exit 1

# Run with gunicorn for production
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "4", "database_server:app"]
