# 🛠️ Linux DevOps Toolkit

> Production-grade automation scripts for Linux server management, Docker deployments, and infrastructure monitoring — actively used in live environments.

---

## 📁 Repository Structure

```
linux-devops-toolkit/
├── bash-scripts/
│   ├── server-health-monitor.sh     # CPU, RAM, Disk, Load & service health checks
│   ├── disk-alert.sh                # Disk usage monitoring with email/webhook alerts
│   ├── backup-automation.sh         # Automated backup with rotation & remote sync
│   └── deploy_with_docker_image.sh  # Blue/Green Docker deployment from Nexus registry
├── docker/
│   └── docker-compose.yml           # Frontend + Backend stack (Nexus-based images)
├── jenkins/
│   └── Jenkinsfile                  # CI/CD pipeline definition
└── monitoring/
    ├── docker-compose.yml           # Prometheus + Grafana + Alertmanager stack
    ├── prometheus/
    │   ├── prometheus.yml           # Prometheus scrape config
    │   └── alert.rules.yml          # Alerting rules
    ├── alertmanager/
    │   └── alertmanager.yml         # Alert routing & notification config
    └── grafana/                     # Grafana provisioning config
```

---

## ⚙️ Scripts Overview

### 🖥️ `server-health-monitor.sh`
Monitors critical server metrics in real-time with configurable thresholds.

**What it checks:**
- CPU usage (sampled from `/proc/stat`)
- Memory usage (via `free`)
- Disk usage per mounted filesystem
- Load average (1-minute)
- Systemd service status (`sshd`, `cron`)
- TCP port availability

**Usage:**
```bash
# Run once
./bash-scripts/server-health-monitor.sh

# Watch mode (every 60 seconds)
./bash-scripts/server-health-monitor.sh --watch 60

# Custom thresholds
CPU_THRESHOLD=90 MEM_THRESHOLD=85 ./bash-scripts/server-health-monitor.sh
```

---

### 💾 `backup-automation.sh`
Automated backup with timestamped archives, retention rotation, SHA256 checksums, and optional remote rsync.

**Features:**
- Compressed `.tar.gz` archives with timestamps
- Configurable retention (default: 7 days)
- SHA256 checksum generation for integrity verification
- Optional remote sync via rsync + SSH
- Restore mode with checksum verification

**Usage:**
```bash
# Run backup
./bash-scripts/backup-automation.sh

# List existing backups
./bash-scripts/backup-automation.sh --list

# Restore a backup
./bash-scripts/backup-automation.sh --restore /var/backups/backup-host-20250101.tar.gz /restore/path

# Custom config
BACKUP_SOURCES="/etc /var/www" RETENTION_DAYS=14 REMOTE_HOST="user@backup-server" ./bash-scripts/backup-automation.sh
```

---

### 🚨 `disk-alert.sh`
Disk usage monitoring with warning/critical thresholds, state tracking (no duplicate alerts), and email/webhook notifications.

**Features:**
- Warning and critical threshold levels (default: 75% / 90%)
- State file tracking — alerts once per breach, not every cron run
- Recovery notification when disk drops below threshold
- Email and Slack/webhook support
- Cron-friendly design

**Usage:**
```bash
# Run check
./bash-scripts/disk-alert.sh

# List current usage
./bash-scripts/disk-alert.sh --list

# Custom thresholds with Slack webhook
WARN_THRESHOLD=75 CRIT_THRESHOLD=90 WEBHOOK_URL="https://hooks.slack.com/..." ./bash-scripts/disk-alert.sh

# Cron (every 15 minutes)
*/15 * * * * /path/to/disk-alert.sh >> /var/log/disk-alert-cron.log 2>&1
```

---

### 🐳 `deploy_with_docker_image.sh`
Blue/Green zero-downtime deployment script — pulls versioned Docker images from a private Nexus registry and switches traffic between environments.

**Features:**
- Blue/Green deployment strategy (zero downtime)
- Pulls versioned images from private Nexus Docker registry
- Auto-detects active color and deploys to inactive slot
- Stops and removes old containers before deploying new ones
- Logs all deployment activity

**Usage:**
```bash
./bash-scripts/deploy_with_docker_image.sh <image-tag>

# Example
./bash-scripts/deploy_with_docker_image.sh v1.2.3
```

---

## 📊 Monitoring Stack

Full observability stack using **Prometheus + Grafana + Alertmanager** — deployed via Docker Compose.

```bash
cd monitoring/
docker compose up -d
```

| Service | Port | Purpose |
|---|---|---|
| Prometheus | 9090 | Metrics collection & alerting rules |
| Grafana | 3000 | Dashboards & visualization |
| Alertmanager | 9093 | Alert routing & notifications |

Default Grafana credentials: `admin / admin123` *(change in production)*

---

## 🚀 Docker App Stack

Frontend + Backend application stack using private Nexus registry images.

```bash
cd docker/
IMAGE_TAG=v1.0.0 docker compose up -d
```

---

## 🔧 Requirements

| Tool | Purpose |
|---|---|
| `bash` ≥ 4.x | All scripts |
| `docker` + `docker compose` | Deployment & monitoring stack |
| `rsync` | Remote backup sync (optional) |
| `mail` / `mailx` | Email alerts (optional) |
| `curl` | Webhook alerts (optional) |
| `systemctl` | Service checks |

---

## 👨‍💻 Author

**Nishant Bisht**
Linux Systems Administrator · DevOps Engineer
- 🔗 [LinkedIn](https://linkedin.com/in/nishant-bisht-564064357)
- 🐙 [GitHub](https://github.com/nishant-devops07)

> All scripts are production-tested on Ubuntu/Debian servers in live infrastructure environments.
