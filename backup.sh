#!/bin/bash
# Load environment variables from .env file
set -a
source .env
set +a
#  ____                                
# |  _ \ _ __ ___ _ __   __ _ _ __ ___ 
# | |_) | '__/ _ \ '_ \ / _` | '__/ _ \
# |  __/| | |  __/ |_) | (_| | | |  __/
# |_|   |_|  \___| .__/ \__,_|_|  \___|
#                |_|                   

# Build the borg container 
echo "Building borg container"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
docker build -t borg-backup "$SCRIPT_DIR"
echo "Borg container built successfully"


#  ____                  _            ____             _                    
# / ___|  ___ _ ____   _(_) ___ ___  | __ )  __ _  ___| | ___   _ _ __  ___ 
# \___ \ / _ \ '__\ \ / / |/ __/ _ \ |  _ \ / _` |/ __| |/ / | | | '_ \/ __|
#  ___) |  __/ |   \ V /| | (_|  __/ | |_) | (_| | (__|   <| |_| | |_) \__ \
# |____/ \___|_|    \_/ |_|\___\___| |____/ \__,_|\___|_|\_\\__,_| .__/|___/
#                                                                |_|        

# Mealie
echo "Creating backup of Mealie"
MEALIE_TARGET_DIR="${TMP_DIR}service-backups/mealie/"
mkdir -p "$MEALIE_TARGET_DIR"
echo "Triggering Mealie backup creation"
curl -s -X 'POST' \
  "${MEALIE_URL}/api/admin/backups" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${MEALIE_API_KEY}" \
  -w '\n%{http_code}' | tail -1 | grep -q 201

if [ $? -eq 0 ]; then
  echo "Mealie backup successfully created, downloading backup file"
  MEALIE_LATEST_BACKUP=$(curl -s -X 'GET' \
  "${MEALIE_URL}/api/admin/backups" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${MEALIE_API_KEY}" | jq -r '.imports[0].name')
  echo "Latest Mealie backup: $MEALIE_LATEST_BACKUP"
  curl -s -X 'GET' \
  "${MEALIE_URL}/api/admin/backups/$MEALIE_LATEST_BACKUP" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${MEALIE_API_KEY}" | jq -r '.fileToken' | \
  xargs -I {} curl -s -o "$MEALIE_TARGET_DIR/$MEALIE_LATEST_BACKUP" \
  "${MEALIE_URL}/api/admin/backups/$MEALIE_LATEST_BACKUP/download?token={}"
  echo "Mealie backup downloaded to $MEALIE_TARGET_DIR$MEALIE_LATEST_BACKUP"

else
  echo "Mealie backup failed during backup creation continuing with next backup"
fi

echo ""
echo ""

# Audiobookshelf
echo "Creating backup of Audiobookshelf"
ADB_TARGET_DIR="${TMP_DIR}service-backups/audiobookshelf/"
mkdir -p "$ADB_TARGET_DIR"
echo "Creating backup of Audiobookshelf to $ADB_TARGET_DIR"
LAST_ADB=$(ls -1 "$AUDIOBOOKSHELF_BACKUP_SRC_LOCATION" | sort | tail -1)
rsync -av "$AUDIOBOOKSHELF_BACKUP_SRC_LOCATION/$LAST_ADB" "$ADB_TARGET_DIR/"
echo "Finished backup of Audiobookshelf"

echo ""
echo ""

# Jellyfin
echo "Stopping Jellyfin"
docker stop $JELLYFIN_CONTAINER_NAME
JELLYFIN_TARGET_DIR="${TMP_DIR}service-backups/jellyfin/"
mkdir -p $JELLYFIN_TARGET_DIR
rsync -ah --exclude='*/cache/*' ${JELLYFIN_CONFIG_PATH} ${JELLYFIN_TARGET_DIR}
echo "Jellyfin backup completed remaining in maintenance mode for borg backup"

echo ""
echo ""

# Paperless-ngx
echo "Creating backup of Paperless-ngx database"
echo "Stopping Paperless-ngx webserver and database containers"
docker stop $PAPERLESS_NGX_SERVER_CONTAINER_NAME
docker stop $PAPERLESS_NGX_DATABASE_CONTAINER_NAME
echo "Finished stopping Paperless-ngx containers. The backup is part of borg backup now."

echo ""
echo ""

# opencloud
echo "Stopping opencloud (incl. Radicale)"
docker stop $OPENCLOUD_RADICALE_CONTAINER_NAME
docker stop $OPENCLOUD_CONTAINER_NAME
echo "Copying opencloud configuration files"
OPENCLOUD_TARGET_DIR="${TMP_DIR}service-backups/opencloud/"
mkdir -p "$OPENCLOUD_TARGET_DIR"
rsync -ah ${OPENCLOUD_CONFIG_DATASET}/* $OPENCLOUD_TARGET_DIR
echo "Finished stopping opencloud containers. The backup is part of borg backup now."

echo ""
echo ""

# Docker Compose files
echo "Copying Docker Compose files"
DOCKER_COMPOSE_TARGET_DIR="${TMP_DIR}service-backups/docker-compose/"
mkdir -p "$DOCKER_COMPOSE_TARGET_DIR"
cp $DOCKER_COMPOSE_FILES "$DOCKER_COMPOSE_TARGET_DIR"
echo "Finished copying Docker Compose files"

echo ""
echo ""

# Immich 
# Put immich server into maintenance mode to avoid inconsistent backups
echo "Putting Immich into maintenance mode"
mkdir -p "${TMP_DIR}service-backups/immich/"
docker exec -d $IMMICH_SERVER_CONTAINER_NAME sh -c "immich-admin enable-maintenance-mode"
# Wait for a few seconds to ensure the command is processed
echo "Waiting 15 seconds to start maintenance mode"
sleep 15
echo "Starting Immich Database dump"
# Backup Immich database
export PGPASSWORD=$IMMICH_DATABASE_PASSWORD
docker exec -t $IMMICH_DATABASE_CONTAINER_NAME pg_dump --clean --if-exists --dbname=$IMMICH_DATABASE_NAME --username=$IMMICH_DATABASE_USERNAME  > "${TMP_DIR}service-backups/immich/immich_database_backup.sql"
echo "Immich database backup completed remaining in maintenance mode for borg backup"

echo ""
echo ""

#  ____        _          ____             _                
# |  _ \  __ _| |_ __ _  | __ )  __ _  ___| | ___   _ _ __  
# | | | |/ _` | __/ _` | |  _ \ / _` |/ __| |/ / | | | '_ \ 
# | |_| | (_| | || (_| | | |_) | (_| | (__|   <| |_| | |_) |
# |____/ \__,_|\__\__,_| |____/ \__,_|\___|_|\_\\__,_| .__/ 
#                                                    |_|    


# Init borg repo if not already initialized
if [ ! -d "$BORG_REPO_PATH" ]; then
  echo "Initializing borg repository at $BORG_REPO_PATH"
  read -p "Do you want to continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Backup process aborted by user. Cleaning up temporary backup files"
    rm -rf ${TMP_DIR}service-backups/
    exit 1
  fi  
  docker run --rm -e BORG_PASSPHRASE="$BORG_PASSPHRASE" -v "$BORG_REPO_PATH:$BORG_REPO_PATH" borg-backup borg init --encryption=repokey-blake2 "$BORG_REPO_PATH"
fi


read -p "Starting borg backup process. Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Backup process aborted by user. Cleaning up temporary backup files"
  rm -rf ${TMP_DIR}service-backups/
  exit 1
fi

# Create borg backup
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_NAME="backup-$TIMESTAMP"

echo "Creating borg backup: $BACKUP_NAME"
docker run --rm -e BORG_PASSPHRASE="$BORG_PASSPHRASE" \
  -v "/mnt/external-backup:/mnt/external-backup" \
  -v "${MASSSTORAGE_DATASET}:${MASSSTORAGE_DATASET}" \
  -v "${PAPERLESS_NGX_DATABASE_FOLDER}:${PAPERLESS_NGX_DATABASE_FOLDER}" \
  -v "${TMP_DIR}service-backups/:${TMP_DIR}service-backups/" \
  -v "${EXCLUDE_FILE}:${EXCLUDE_FILE}" \
  -v "${BORG_REPO_PATH}:${BORG_REPO_PATH}" \
  borg-backup borg create --stats --progress -C lz4 \
  --exclude-from "$EXCLUDE_FILE" \
  "${BORG_REPO_PATH}::${BACKUP_NAME}" \
  "${MASSSTORAGE_DATASET}" \
  "${TMP_DIR}service-backups/" \
  "${PAPERLESS_NGX_DATABASE_FOLDER}"

#  ____                  _            ____                       _     _      
# / ___|  ___ _ ____   _(_) ___ ___  |  _ \ ___  ___ _ __   __ _| |__ | | ___ 
# \___ \ / _ \ '__\ \ / / |/ __/ _ \ | |_) / _ \/ _ \ '_ \ / _` | '_ \| |/ _ \
#  ___) |  __/ |   \ V /| | (_|  __/ |  _ <  __/  __/ | | | (_| | |_) | |  __/
# |____/ \___|_|    \_/ |_|\___\___| |_| \_\___|\___|_| |_|\__,_|_.__/|_|\___|

#Immich leave maintenance mode
echo "Taking Immich out of maintenance mode"
docker exec -d $IMMICH_SERVER_CONTAINER_NAME sh -c "immich-admin disable-maintenance-mode"
echo "Immich is restored to normal operation"

#Paperless-ngx restart containers
echo "Restarting Paperless-ngx webserver and database containers"
docker start $PAPERLESS_NGX_DATABASE_CONTAINER_NAME
docker start $PAPERLESS_NGX_SERVER_CONTAINER_NAME
echo "Finished restarting Paperless-ngx containers"

# opencloud
echo "Restarting opencloud (incl. Radicale)"
docker start $OPENCLOUD_RADICALE_CONTAINER_NAME
docker start $OPENCLOUD_CONTAINER_NAME
echo "Finished starting opencloud containers."

# Jellyfin
echo "Restarting Jellyfin"
docker start $JELLYFIN_CONTAINER_NAME
echo "Finished starting Jellyfin containers."

# Cleanup temporary backup files
echo "Cleaning up temporary backup files"
rm -rf ${TMP_DIR}service-backups/
echo "Backup process completed successfully"
