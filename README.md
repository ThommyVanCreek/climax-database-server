# ClimaX Server

Production database backend for the ClimaX smart security & climate system. This is a standalone project that provides:
- **PostgreSQL database** for event logging, climate history, and battery tracking
- **Flask REST API** for data ingestion from the ClimaX Bridge
- **Deployment scripts** for Proxmox LXC containers and Docker

Related projects:
- `climax-bridge/` — ESP32-C6 HomeKit bridge that sends data to this server
- `climax-sensor/` — Battery-powered door/window sensors

## Quick Start

### Option 1: LXC Container (Proxmox)
```bash
chmod +x proxmox-create-lxc.sh
./proxmox-create-lxc.sh

# SSH into container, then:
chmod +x lxc-setup.sh
./lxc-setup.sh
```

### Option 2: Docker Compose
```bash
docker-compose up -d
```

### Option 3: Manual Setup
```bash
pip install -r requirements.txt
python database_server.py
```

## Configuration

Set environment variables in `.env`:
```
DATABASE_URL=postgresql://climax:password@localhost:5432/climax
API_KEY=your_secure_key
PORT=5000
DEBUG=false
```

## Database

- **Host**: 172.22.0.220 (from Proxmox setup)
- **Database**: climax
- **User**: climax
- **Port**: 5432

Run schema: `psql -U climax -d climax -f database_schema.sql`

## API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/log/event` | Log system event |
| POST | `/api/log/climate` | Log climate reading |
| POST | `/api/log/battery` | Log battery status |
| POST | `/api/log/alarm` | Log alarm event |
| GET | `/api/events` | Query events |
| GET | `/api/sensors` | List all sensors |
| GET | `/api/health` | Health check |

## Bridge Configuration

Edit `src/config/database.h` in the **climax-bridge** project:
```cpp
#define DB_LOGGING_ENABLED    true
#define DB_API_HOST           "172.22.0.220"
#define DB_API_PORT           5000
#define DB_API_KEY            "your_api_key_here"
```

Get API_KEY from container:
```bash
ssh root@172.22.0.220 'grep API_KEY /opt/climax/.env | cut -d= -f2'
```

## Files

- `database_server.py` - Flask API server
- `database_schema.sql` - PostgreSQL schema
- `docker-compose.yml` - Docker deployment
- `Dockerfile` - Container definition
- `lxc-setup.sh` - Alpine LXC setup
- `proxmox-create-lxc.sh` - Proxmox provisioning
- `requirements.txt` - Python dependencies

## Support

- API logs: `journalctl -u climax-api -f` (in container)
- DB connection: `psql -U climax -h 172.22.0.220 -d climax`
- Docker logs: `docker-compose logs -f api`
