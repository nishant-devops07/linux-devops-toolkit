#!/bin/bash
set -euo pipefail

###############################################################################
# ENV VARIABLES
###############################################################################
ENV="DEV"
APP_DIR="App directory"
IMAGE_NAME="image_name"
CONTAINER_NAME="image_name"
HOST_PORT=3006
CONTAINER_PORT=3000
BASE_DIR="App directory"
ENV_DIR="${BASE_DIR}/environment/${ENV}"
RUNTIME_DIR="${BASE_DIR}/runtime/${ENV}"
ACTIVE_COLOR_FILE="${RUNTIME_DIR}/ACTIVE_COLOR"
LOG_FILE="/var/log/deploy.log"

cd "$APP_DIR" || { echo "App directory not found"; exit 1; }
mkdir -p "$ENV_DIR" "$RUNTIME_DIR"

VERSION="${1:-}"
IMAGE_TAG="$VERSION"


echo ">>> Docker"
echo "Environment: $ENV"
echo "Version: $VERSION"

# Blue/Green detection
if [ -f "$ACTIVE_COLOR_FILE" ]; then
  ACTIVE=$(cat "$ACTIVE_COLOR_FILE")
else
  ACTIVE="blue"
fi

if [ "$ACTIVE" = "blue" ]; then
  NEW="green"
else
  NEW="blue"
fi

echo "Active color: $ACTIVE"
echo "Deploying new color: $NEW"

# ==========================
# Nexus Configuration
# ==========================
NEXUS_REGISTRY="nexus:9092"
NEXUS_USERNAME="admin"
NEXUS_PASSWORD="Password"
REPOSIOTRY="repo"
BRANCH="dev"

echo "========== Frontend Deployment Started: $(date) ==========" | tee -a "$LOG_FILE"
echo "📦 Deploying image tag: ${IMAGE_TAG}" | tee -a "$LOG_FILE"

# Check directory
if [ ! -d "$APP_DIR" ]; then
    echo "❌ Directory not found: $APP_DIR" | tee -a "$LOG_FILE"
    exit 1
fi

cd "$APP_DIR"

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed." | tee -a "$LOG_FILE"
    exit 1
fi


# Login to Nexus
echo "🔐 Logging into Nexus..." | tee -a "$LOG_FILE"
echo "${NEXUS_PASSWORD}" | docker login "${NEXUS_REGISTRY}" \
    --username "${NEXUS_USERNAME}" \
    --password-stdin | tee -a "$LOG_FILE"

#Pull the Docker image

echo "Pulling the Image for deployment ${IMAGE_TAG}"

SOURCE_IMAGE="${NEXUS_REGISTRY}/${REPOSIOTRY}/${BRANCH}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "${SOURCE_IMAGE}"

docker pull "$SOURCE_IMAGE"

LOCAL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Tagging image..."
docker tag "$SOURCE_IMAGE" "$LOCAL_IMAGE"

docker stop "${CONTAINER_NAME}-${ACTIVE}" 2>/dev/null || true
docker rm "${CONTAINER_NAME}-${ACTIVE}" 2>/dev/null || true
docker rm "${CONTAINER_NAME}-${NEW}" 2>/dev/null || true

#docker run -d \
#    --env-file "$APP_DIR/.env" \
#    -p ${HOST_PORT}:${CONTAINER_PORT} \
#    --name "${CONTAINER_NAME}-${NEW}" \
#    --restart unless-stopped \
#    "$LOCAL_IMAGE"

docker run -d \
    -p ${HOST_PORT}:${CONTAINER_PORT} \
    --name "${CONTAINER_NAME}-${NEW}" \
    --restart unless-stopped \
    "$LOCAL_IMAGE"



###############################################################################
# Switch traffic
###############################################################################

echo "$NEW" > "$ACTIVE_COLOR_FILE"

echo "Deployment successful!"
echo "App running on port $HOST_PORT"
