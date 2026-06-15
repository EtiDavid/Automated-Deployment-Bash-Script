# Automated Deployment Bash Script

A deployment automation script that connects to a remote Linux server via SSH, validates the environment, installs dependencies, deploys a Dockerized application from GitHub, configures an Nginx reverse proxy, and verifies application health post-deployment.

## Tested Platforms

| Platform | Status |
|---|---|
| Ubuntu Server (AWS) |  Full support |
| Debian Server (VMware) | Full support |
| Amazon Linux 2023 (AWS) |  Full support |
| Red Hat Enterprise Linux 10 (AWS) | ⚠Partial — requires manual Docker CE repository setup |

> **Note:** RHEL locks its base repositories behind commercial subscriptions. Unregistered developer machines cannot access standard application registries. Docker must be installed manually or replaced with Podman.

---

## Architecture Overview

```
Client Input / .env
        │
        ▼
Input Collection & Validation
        │
        ▼
SSH → Remote Server Inspection (OS detection, package manager)
        │
        ▼
Dependency Management (Docker, Git, Nginx)
        │
        ▼
Repository Deployment (clone or pull)
        │
        ▼
Docker Validation → Build Image
        │
        ▼
Container Deployment (remove old → start new)
        │
        ▼
Health Verification (curl check)
        │
        ▼
Nginx Reverse Proxy Configuration
        │
        ▼
Post-Deployment Validation
```

---

## How It Works

### 1. Input Collection and Validation

Parameters are loaded from a `.env` file if present. Any missing values are prompted interactively.

```bash
if [ -f .env ]; then
  log "env file found. Reading values from env."
  source .env
fi
```

**Required parameters:**
- Repository URL
- GitHub Personal Access Token (PAT)
- Branch name
- Server username
- Server IP address
- SSH private key path
- Application port

**Validation includes:**
- IP address format check (regex)
- SSH key existence and permission hardening (`chmod 400`)
- Port number range validation
- Optional ping test (non-blocking — some servers block ICMP but allow SSH)

**Logging** — every step is written to `deploy.log` in the script's starting directory:

```bash
SCRIPT_PATH="$(pwd)"
LOGFILE_PATH="$SCRIPT_PATH/deploy.log"

log() {
    echo "$(date) - $*" | tee -a "$LOGFILE_PATH"
}
```

> **Windows `.env` files** add `\r\n` line endings. Linux only understands `\n`, causing variables to carry a trailing `\r`. All variables are sanitised on load:
> ```bash
> SERVER_IP=$(echo "$SERVER_IP" | tr -d '\r' | xargs)
> ```

---

### 2. Remote Server Inspection

A reusable `remote_exec` function avoids repeating the SSH connection block for every remote command:

```bash
remote_exec() {
    ssh -i "$SSH_KEY" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        "$SERVER_USER@$SERVER_IP" \
        'bash -s' <<EOF 2>&1
$1
EOF
}
```

The script then detects the remote OS and assigns the correct package manager:

```bash
OS_ID=$(remote_exec 'source /etc/os-release && echo "$ID"')
```

**Supported OS / package manager mappings:**

| OS | Package Manager | Docker Package |
|---|---|---|
| Ubuntu / Debian | `apt` / `apt-get` | `docker.io` |
| Amazon Linux 2023 / Fedora | `dnf` | `docker` |
| CentOS | `yum` | `docker` |

---

### 3. Dependency Management

Before installing anything, the script checks whether each package already exists and whether its service is active.

```bash
DOCKER_STATS=$(remote_exec "sudo systemctl status docker")
if [[ $DOCKER_STATS == *"Active"* ]]; then
  log "Docker is active and running"
else
  log "Docker failed to start"
  exit 1
fi
```

The remote user is also added to the `docker` group to allow non-root Docker commands (required for automation):

```bash
remote_exec "sudo usermod -aG docker $SERVER_USER"
# -aG appends to existing groups; omitting -a would overwrite them
```

For Nginx, the default site config is removed and replaced with a custom reverse proxy config:

```bash
remote_exec "sudo rm /etc/nginx/sites-enabled/default"
remote_exec "sudo touch /etc/nginx/conf.d/$REPO_NAME.conf"
```

---

### 4. Repository Deployment

The remote application directory is stored in a variable to avoid path errors after each SSH reconnection:

```bash
REMOTE_APP_DIR="/home/$SERVER_USER/$REPO_NAME"
```

The script checks whether the repo already exists (using `.git` to confirm it's a valid Git repo, not just a folder):

- **Exists** → `git fetch`, `git checkout`, `git pull`
- **Missing** → `git clone` using PAT-injected URL

```bash
AUTH_REPO_URL=$(echo "$REPO_URL" | sed "s|https://|https://$PAT@|")
```

---

### 5. Docker Validation and Build

The script checks for a `Dockerfile` before proceeding. It exits if one is not found:

```bash
if [ "$VERIFY_DOCKER_FILE" = "EXIST" ]; then
  log 'Docker deployment files found'
else
  log 'ERROR: No Dockerfile or docker-compose.yml found'
  exit 1
fi
```

If validation passes, the image is built:

```bash
docker build -t '$REPO_NAME' .
```

---

### 6. Container Deployment

Any existing container with the same name is removed first to avoid port and name conflicts, then a fresh container is started:

```bash
docker rm -f '$REPO_NAME' 2>/dev/null || true
```

> `|| true` prevents the script from exiting if no existing container is found.

The script verifies the new container is running after startup:

```bash
docker ps --filter 'status=running' --format '{{.Names}}'
```

---

### 7. Health Verification

The container endpoint is tested with `curl`:

```bash
APP_STATUS=$(remote_exec "curl -s localhost:'$APP_PORT'")
HEALTH_STATUS=$?
# $? = 0 (success) or 1 (failed)
```

---

### 8. Nginx Reverse Proxy Configuration

If the config file is empty, missing, or invalid, a new one is written using a heredoc:

```bash
write_nginx_config() {
  remote_exec "
sudo tee /etc/nginx/conf.d/$REPO_NAME.conf >/dev/null <<- 'NGINX'
server {
  listen 80;
  server_name localhost;

  location / {
    proxy_pass http://127.0.0.1:$APP_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
  "
}
```

The config is validated and Nginx is reloaded safely:

```bash
validate_nginx_config() {
  NGINX_SYNTAX_VALIDATION=$(remote_exec "sudo nginx -t 2>&1")
  if [ $? -eq 0 ]; then
    remote_exec "sudo systemctl reload nginx"
  else
    log "ERROR: Nginx configuration syntax failed."
    exit 1
  fi
}
```

**Traffic flow:** `Client → Nginx (port 80) → Docker Container (APP_PORT)`

---

### 9. Post-Deployment Validation

The final step tests the public-facing endpoint and logs the result:

```bash
ENDPOINT=$(remote_exec "curl -s $SERVER_IP")
if [ -n "$ENDPOINT" ] && [[ "$ENDPOINT" == *"$APP_STATUS"* ]]; then
  log "Script was successful"
else
  log "Something went wrong"
  log "Fallback Endpoint Output: $ENDPOINT"
fi
```

---

## Testing & Platform-Specific Issues

### Amazon Linux 2023 / Ubuntu (AWS EC2)
No issues — both worked as expected.

### Debian (VMware)

**Issue 1 — Non-interactive sudo prompts stalling the SSH session:**
AWS cloud images are pre-configured to allow passwordless sudo. A fresh VMware Debian install requires a password confirmation, which stalls in a non-interactive SSH pipeline.

**Fix:** Added the deployment user to the sudoers file:
```bash
sudo visudo
# Append:
username ALL=(ALL) NOPASSWD:ALL
```

**Issue 2 — `apt-get update` failing due to a stale CD-ROM source entry:**
Debian installed from a local ISO maps the virtual DVD drive as a primary package source. When the drive is disconnected, `apt-get update` aborts with a `cdrom://` error.

**Fix:** Comment out the `deb cdrom:` line at the top of `/etc/apt/sources.list`.

### Red Hat Enterprise Linux (AWS)

**Issue 1 — `dnf update` triggering a full system upgrade:**
Unlike `apt-get update` (which only refreshes package indexes), `dnf update` on RHEL pulls every available OS patch. This was abstracted per-OS:

```bash
# For RHEL targets, skip the update step entirely
UPDATE_COMMAND="true"  # built-in Bash no-op
```

**Issue 2 — Docker unavailable in default RHEL repositories:**
RHEL's base repositories are gated behind a commercial subscription. Docker is not available without registration.

**Current handling:**
```bash
rhel)
  log "Docker package not available in default RHEL repositories."
  log "Please install Docker CE manually or use Podman."
  ;;
```

---

## Lessons Learned

- Bash function design and modular script structure
- Remote command execution over SSH
- Linux package management differences across distributions
- Docker image lifecycle management
- Container health validation techniques
- Nginx reverse proxy configuration
- Heredoc usage and debugging
- Cross-distribution compatibility challenges
- Deployment automation workflows

---

## Known Limitations

The current deployment uses a **recreate** strategy:

1. Stop existing container
2. Remove container
3. Start new container with latest image

This introduces **brief downtime** between container termination and startup.

---

## Future Improvements

-  Blue/Green deployments
-  Rolling deployments
-  Zero-downtime container replacement
-  Automated rollback on deployment failure
-  Load balancer integration
-  AWS ECS/Fargate deployment support
-  Health-check-based deployment gates