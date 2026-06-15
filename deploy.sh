#!/bin/bash

SCRIPT_PATH="$(pwd)"
LOGFILE_PATH="$SCRIPT_PATH/deploy.log"
IP_REGEX="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"


#function to log event
log() {
    echo "$(date) - $*" | tee -a "$LOGFILE_PATH"
}

if [ -f .env ]; then
  log "env file found. Reading values from env"
    source .env
fi

#function to connect remotely
remote_exec() {
    ssh -i "$SSH_KEY" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        "$SERVER_USER@$SERVER_IP" \
        'bash -s' <<EOF 2>&1
$1
EOF
}
# -o ConnectTimeout=10 \ means after 10 seconds and there is no connection then timeout
# -o StrictHostKeyChecking=no .. means bypass the yes or no fingerprint question
####
#
 write_nginx_config() {
   log "Writing Nginx configuration..."
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

#
validate_nginx_config() {
  log "Validating Nginx syntax..."
  NGINX_SYNTAX_VALIDATION=$(remote_exec "sudo nginx -t 2>&1")
    if [ $? -eq 0 ]; then
      log "Nginx syntax is perfect. Reloading service..."
      remote_exec "sudo systemctl reload nginx"
    else
      log "ERROR: Nginx configuration syntax failed."
      log "$NGINX_SYNTAX_VALIDATION"
      exit 1
    fi

}


log "Deployment script started"

# get the repo details 
####
REPO_URL=${REPO_URL:-}
REPO_URL=$(echo "$REPO_URL" | tr -d '\r' | xargs)
if [ -z "$REPO_URL" ]; then
  read -p "Enter repository URL: " REPO_URL
fi
log "Repository URL received"


####
PAT=${PAT:-}
PAT=$(echo "$PAT" | tr -d '\r' | xargs)
if [ -z "$PAT" ]; then
  read -s -p "Enter GitHub PAT: " PAT
fi
log "PAT received"

###
BRANCH=${BRANCH:-}
if [ -z "$BRANCH" ]; then
  read -p "Branch (default main): " BRANCH
  BRANCH=${BRANCH:-main}
  log "Branch set to $BRANCH"
fi
log "Branch received"



# Server details and validation

####
SERVER_USER=${SERVER_USER:-}
SERVER_USER=$(echo "$SERVER_USER" | tr -d '\r' | xargs)
if [ -z "$SERVER_USER" ]; then
  read -p "Server username: " SERVER_USER
fi
log "server username - $SERVER_USER"


##
SERVER_IP=${SERVER_IP:-}
# DEFENSIVE FIX: Strip out any invisible carriage returns (\r) or accidental trailing spaces
SERVER_IP=$(echo "$SERVER_IP" | tr -d '\r' | xargs)
if [ -z "$SERVER_IP" ]; then
  read -p "Server IP: " SERVER_IP
fi
log "Server IP-$SERVER_IP"

# validate ip address
if ! [[ "$SERVER_IP" =~ $IP_REGEX ]]; then
    log "ERROR: Invalid IP format"
    exit 1
fi
log "IP validated"

#Pinging IP to verify network
log "Pinging server to verify network path..."
if ping -c 2 -W 3 "$SERVER_IP" >/dev/null 2>&1; then
    log "Server is responding to pings"
else
    log "WARNING: Server is not responding to pings. Checking if SSH port is open anyway..."
fi


##
SSH_KEY=${SSH_KEY:-}
SSH_KEY=$(echo "$SSH_KEY" | tr -d '\r' | xargs)
if [ -z "$SSH_KEY" ]; then
  read -p "SSH key path: " SSH_KEY
fi

# validate SSH Key
if [ ! -f "$SSH_KEY" ]; then
    log "ERROR: SSH key not found"
    exit 1
fi
log "SSH key verified"

#ensure SSH_Key is saved with relative path
SSH_KEY=$(realpath "$SSH_KEY")
log "SSH key absolute path resolved"

# Secure the key file permissions right before testing
chmod 400 "$SSH_KEY"
log "SSH key now secured"






##
APP_PORT=${APP_PORT:-}
APP_PORT=$(echo "$APP_PORT" | tr -d '\r' | xargs)
if [ -z "$APP_PORT" ]; then
  read -p "Application port: " APP_PORT
fi
log "Application port - $APP_PORT"

# validate port is numeric
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
    log "ERROR: Port must be numeric"
    exit 1
fi

log "Port validated"


####
log "Deployment parameters summary"

echo
echo "Repository : $REPO_URL"
echo "Branch     : $BRANCH"
echo "User       : $SERVER_USER"
echo "Server IP  : $SERVER_IP"
echo "Port       : $APP_PORT"
echo


####


##
#get repo-basename
REPO_NAME=$(basename "$REPO_URL" .git)
log "Repository name: $REPO_NAME"

# Authenticate the URL with the PAT token smoothly
#sed finds and replaces using | as separator
AUTH_REPO_URL=$(echo "$REPO_URL" | sed "s|https://|https://$PAT@|")



# SERVER INSPECTION
log "inspecting server....."

# test SSH connectivity
log "Testing SSH_connection"
SSH_ERROR=$(remote_exec "whoami")
SSH_STATUS=$?
log "SSH_status = $SSH_STATUS"
if [ $SSH_STATUS -eq 0 ]; then
    log "SSH connection successful"
    log "user is $SSH_ERROR"
else
    log "ERROR: SSH connection failed to $SERVER_USER@$SERVER_IP"
    log "REASON FROM SSH: $SSH_ERROR"
    exit 1
fi
####

#Checking remote hostname
log "Checking remote hostname"
log "Remote hostname: $(remote_exec "hostname")"
####


#Checking remote working directory
log "Checking remote working directory"
log " Remote working directory: $(remote_exec "pwd")"
####

#Detecting remote operating system
log "Detecting remote operating system"
OS_ID=$(remote_exec 'source /etc/os-release && echo "$ID"')
log "Remote OS = $OS_ID"

#set package manager for OS
log "determining package manager....."
case "$OS_ID" in

    ubuntu|debian)
        PACKAGE_MANAGER="apt"
        DOCKER_PACKAGE="docker.io"
        PACKAGE_UPDATE="sudo $PACKAGE_MANAGER update"
        ;;

    amzn|fedora)
        PACKAGE_MANAGER="dnf"
        DOCKER_PACKAGE="docker"
        PACKAGE_UPDATE="true"
        ;;

    centos)
        PACKAGE_MANAGER="yum"
        DOCKER_PACKAGE="docker"
        PACKAGE_UPDATE="true"
        ;;

    rhel)
      log "Docker package not available in default RHEL repositories."
      log "Please install Docker CE manually or use Podman."
      ;;

    *)
        log "Unsupported OS: $OS_ID"
        exit 1
        ;;

esac
log "Package manager = $PACKAGE_MANAGER"
log "DOCKER PACKAGE=$DOCKER_PACKAGE"



#Check Docker
log "Checking Docker"
DOCKER_VERSION=$(remote_exec "docker --version")
DOCKER_STATUS=$?
if [ $DOCKER_STATUS -eq 0 ]; then
    log "Docker installed: $DOCKER_VERSION"
    log "Starting up docker....."
    remote_exec "
    sudo systemctl enable docker &&
    sudo systemctl start docker"
    DOCKER_STATS=$(remote_exec "sudo systemctl status docker")
    if [[ $DOCKER_STATS == *"Active"* ]]; then
      log "Docker is active and running"
    else
      log "Docker failed to start"
      exit 1
    fi
else
    log "Docker not installed"
    log "Installing Docker"

    remote_exec "
            $PACKAGE_UPDATE &&
            sudo $PACKAGE_MANAGER install $DOCKER_PACKAGE -y &&
            sudo systemctl enable docker &&
            sudo systemctl start docker"

    DOCKER_VERSION=$(remote_exec "docker --version")
    if [ $? = 0 ]; then
      log "Docker installed: $DOCKER_VERSION"
    else
      log "Docker not installed"
      exit 1
    fi

fi
####
#verify if user is in Docker group
log "Checking if $SERVER_USER is in docker group"
USER_GROUPS=$(remote_exec "
groups
")

if [[ "$USER_GROUPS" = *"docker"* ]]; then
  log "user is in docker group"
else
  log "user is not in docker group"
  log "adding user to docker group"
  remote_exec "sudo usermod -aG docker $SERVER_USER"

  GROUP_ADD_ERROR=$?
  if [ $GROUP_ADD_ERROR -ne 0 ]; then
    log "Error failed to add $SERVER_USER to docker group"
    log " ERROR CODE: $GROUP_ADD_ERROR"
  exit 1
  else
    log "User successfully added to docker group"
fi

fi



# Check NGINX
log "Checking Nginx"
NGINX_VERSION=$(remote_exec "nginx -v" 2>&1)
NGINX_STATUS=$?

if [ $NGINX_STATUS -eq 0 ]; then
    log "Nginx installed"
    remote_exec "
    sudo systemctl enable nginx &&
    sudo systemctl start nginx" >/dev/null 2>&1

    NGINX_VERSION=$(remote_exec "nginx -v 2>&1")
    log "Nginx installed: $NGINX_VERSION"
else
    log "Nginx not installed"
    log "Installing Nginx"
    remote_exec "
            sudo $PACKAGE_MANAGER update >/dev/null  &&
            sudo $PACKAGE_MANAGER install nginx -y >/dev/null  &&
            sudo systemctl enable nginx >/dev/null  &&
            sudo systemctl start nginx >/dev/null  "
    if [ $? -ne 0 ]; then
        log "ERROR: Nginx installation pipeline failed on the remote server."
        exit 1
    else
        log "Nginx successfully installed, enabled, and started!"
        NGINX_VERSION=$(remote_exec "nginx -v 2>&1")
            log "Nginx installed: $NGINX_VERSION"
    fi

fi
####
# removing nginx default config
log "checking nginx default config file"
NGINX_DEFAULT=$(remote_exec "
cd /etc/nginx/sites-enabled
  if [ -f 'default' ]; then
    echo EXIST
  else
    echo EMPTY
  fi ")
if [[ $NGINX_DEFAULT == *"EXIST"* ]]; then
  log "nginx default config file exist"
  log "deleting nginx default config file "
  remote_exec "sudo rm /etc/nginx/sites-enabled/default"
else
  log "nginx default config file doesn't exist"
fi

#checking reverse proxy config file
log "checking reverse proxy config file "
NGINX_NEW_DEFAULT=$(remote_exec "
cd /etc/nginx/conf.d
  if [ -f '$REPO_NAME.conf' ]; then
    echo EXIST
  else
    echo EMPTY
  fi ")
if [[ $NGINX_NEW_DEFAULT == *"EXIST"* ]]; then
  log "nginx proxy config file exist"
else
  log "creating an empty proxy file"
  remote_exec "sudo touch /etc/nginx/conf.d/$REPO_NAME.conf"
  if [ $? -eq 0 ]; then
    log "Empty $REPO_NAME.conf created"
  else
    log "error in creating file"
  fi
fi

#Check Git
log "Checking Git"
GIT_VERSION=$(remote_exec "git --version")
GIT_STATUS=$?
if [ $GIT_STATUS -eq 0 ]; then
    log "git is installed"
    log "Git installed: $GIT_VERSION"
else
    log "Git not installed"
    remote_exec "
                sudo $PACKAGE_MANAGER update &&
                sudo $PACKAGE_MANAGER install git -y"
    log "Git installed: $GIT_VERSION"

fi
####

#clone repo to remote server
REMOTE_APP_DIR="/home/$SERVER_USER/$REPO_NAME"
# Clone repository
log "verifying if repo exist"
VERIFY_REMOTE_PATH=$(remote_exec "
  if [ -d '$REMOTE_APP_DIR/.git' ]; then
    echo 'EXIST'
  else
    echo 'MISSING'
fi
")
log "Repo status = $VERIFY_REMOTE_PATH"
if [ "$VERIFY_REMOTE_PATH" = "EXIST" ]; then
  log "Pulling latest changes to $REPO_NAME....."
   REMOTE_REPO=$(remote_exec "
      cd '$REMOTE_APP_DIR' || exit 1
      pwd
      git fetch origin
      git checkout '$BRANCH' || exit 1
      git pull origin '$BRANCH' || exit 1 ")
      if [ $? -eq 0 ]; then
          log "Pulled lastest changes to $REPO_NAME."
      else
          log "ERROR: Remote pulling and setup sequence failed."
          log "ERROR = $REMOTE_REPO"
          exit 1
      fi

else
    log "Cloning repository....."
    REMOTE_REPO=$(remote_exec "
    git clone '$AUTH_REPO_URL' '$REMOTE_APP_DIR' || exit 1
    cd '$REMOTE_APP_DIR' || exit 1
    git checkout '$BRANCH' || exit 1
    pwd ")
    if [ $? -eq 0 ]; then
            log "successful Cloned '$REPO_NAME' repository "
          else
            log "ERROR: Remote cloning and setup sequence failed."
            log "ERROR = $REMOTE_REPO"
            exit 1
          fi


fi
# verify dockerfile or docker-compose file exist

VERIFY_DOCKER_FILE=$(remote_exec "
cd '$REMOTE_APP_DIR' || exit 1
if [ -f 'Dockerfile' ] || [ -f 'docker-compose.yml' ]; then
    echo 'EXIST'

else
    echo 'MISSING'

fi ")

log "docker files status = $VERIFY_DOCKER_FILE"

if [ "$VERIFY_DOCKER_FILE" = "EXIST" ]; then
  log 'Docker deployment files found'
else
  log 'ERROR: No Dockerfile or docker-compose.yml found'
  exit 1
fi

#build docker image
log "building docker image"
DOCKER_IMAGE=$(remote_exec "
cd '$REMOTE_APP_DIR' || exit 1
docker build -t '$REPO_NAME' .
")
IMAGE_STATUS=$?

if [ $IMAGE_STATUS -eq 0 ]; then
 log "docker image built successfully"
 log "$(remote_exec "docker images '$REPO_NAME' --format '{{.Repository}}:{{.Tag}}'")"
else
  log "docker image build failed"
  log "$DOCKER_IMAGE"
  exit 1
fi

log "removing exiting containers"
remote_exec "
docker rm -f '$REPO_NAME' >/dev/null 2>&1 || true
"

log "starting container"
DOCKER_CONTAINER=$(remote_exec "
docker run -d --name '$REPO_NAME' -p '$APP_PORT':80 '$REPO_NAME' || exit 1
")
CONTAINER_STATUS=$?
if [ $CONTAINER_STATUS = 0 ]; then
 log "Container started successfully "
else
 log "Container failed to start"
 log "Container startup Error : $DOCKER_CONTAINER"
 exit 1

fi

log "Checking if container is running "
IS_CONTAINER_RUNNING=$(remote_exec "
docker ps --filter 'status=running' --format '{{.Names}}'
")

if [[ "$IS_CONTAINER_RUNNING" == *"$REPO_NAME"* ]]; then
  log "$REPO_NAME is running"
else
  log "Container failed to start"
  log "$(remote_exec "docker logs '$REPO_NAME' 2>&1 | tail -n 20")"
  exit 1
fi

log "Checking Container's Health"
APP_STATUS=$(remote_exec " curl -s localhost:'$APP_PORT'")
HEALTH_STATUS=$?

if [[ $HEALTH_STATUS -eq 0 && "$APP_STATUS" == *"<!DOCTYPE html>"* ]]; then
  log "Container is Healthy"
else
  log "container is not responsive"
  log "$APP_STATUS"
  exit 1
fi

log "Checking reverse proxy setting"
NGINX_CONFIG_FILE=$(remote_exec "
cat /etc/nginx/conf.d/$REPO_NAME.conf 2>/dev/null
")
NCF_STATUS=$?

if [[ $NCF_STATUS -eq 0  ]]; then
  if [[ "$NGINX_CONFIG_FILE" == *"proxy_pass http://127.0.0.1:$APP_PORT"* ]]; then
    log "NGINX reverse proxy is configured"
    log "Validating Nginx syntax..."
    NGINX_SYNTAX_VALIDATION=$(remote_exec "sudo nginx -t 2>&1")
    if [ $? = 0 ]; then
      log "Nginx syntax is perfect."
    else
      log "Nginx syntax failed"
      log "over-writing Nginx configuration"
      write_nginx_config
      validate_nginx_config
    fi
  else
    log "NGINX reverse proxy is not configured"
    log "Creating Nginx reverse proxy configuration for $REPO_NAME..."
    write_nginx_config
    validate_nginx_config
  fi
fi

#testing endpoint
log "testing reverse proxy end point"
ENDPOINT=$(remote_exec "curl -s $SERVER_IP")
if [ -n "$ENDPOINT" ] && [[ "$ENDPOINT" == *"$APP_STATUS"* ]]; then
  log "Script was successful"
else
  log " Something went wrong"
  log "Fallback Endpoint Output: $ENDPOINT"
fi