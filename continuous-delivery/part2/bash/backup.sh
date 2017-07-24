#!/bin/bash
# 
# Daily Backup
#

BACKUP_DIR=/data/backup
BACKUP_RSYNC_REMOTE=backup@backup.tupadr3.de:/data/backup/dev.tupadr3
BACKUP_RSYNC_SSH="ssh -p 2605 -T -o Compression=no -x -c aes128-ctr -i /data/config/ssh/dev.tupadr3@backup.tupadr3.de"
BORG_PASSPHRASE='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'


function backupSetup()
{
	log "Creating temp dirs..."

	mkdir $TEMP_DIR/docker -p 2>/dev/null	
}

function backupFiles()
{
	log "Creating new gitlab backup..."
	docker exec gitlab sudo -HEu git bundle exec rake gitlab:backup:create >> $LOG_FILE
	
	log "Preliminary rsync..."
	rsync -vra --stats --exclude-from "/data/config/scripts/exclude.txt" /data/docker/ --progress $TEMP_DIR/docker/ --delete >> $LOG_RSYNC_FILE

	log "Shutting down containers..."
	docker stop gitlab >> $LOG_FILE
	docker stop gitlab-postgresql >> $LOG_FILE
	docker stop nexus >> $LOG_FILE

	log	"Waiting 10s for containers to stop, just in case..."
	sleep 10

	log	"Cleaning up old log files..."
	find /data/logs/cron* -mtime +5 -exec rm {} \;
	find /data/logs/gitlab* -mtime +5 -exec rm {} \;
	find /data/logs/nginx* -mtime +5 -exec rm {} \;

	log "Rsync docker dir..."
	rsync -vra --stats --exclude-from "/data/config/scripts/exclude.txt" /data/docker/ --progress $TEMP_DIR/docker/ --delete >> $LOG_RSYNC_FILE

	log "Restarting the remaining containers"
	docker start gitlab-postgresql >> $LOG_FILE
	docker start gitlab >> $LOG_FILE
	docker start nexus >> $LOG_FILE

	log	"Waiting 10s for containers to start"
	sleep 10

}

function backupDatabase()
{
	log "No databases to backup..."
}

function backupBorg()
{

	# creat if not one already exists 
	borg init $BORG_REPO 2>/dev/null

	# borg make local backup
	borg create --compression lz4 -v --progress --stats --exclude-caches ::'{hostname}-{now:%Y-%m-%d-%s}' \
	 	/etc/apt/sources.list  \
	 	/etc/apt/sources.list.d \
	 	/data/config \
	 	/data/www \
	 	$TEMP_DIR/docker \
	>> $LOG_FILE
	 
	# borg housekeeping
	borg prune -v --list $BORG_REPO --prefix '{hostname}-' \
		--keep-daily 7 \
		--keep-weekly 5 \
		--keep-monthly 6 \
	>> $LOG_FILE
}	

function backupCleanup()
{
	log "Housekeeping for docker..."
	
	docker system prune -f
	docker volume prune -f
	docker network prune -f
	docker container prune -f
	
	#docker image prune -f
	# remove exited containers
	#docker ps --filter status=dead --filter status=exited -aq | xargs -r docker rm -v >> $LOG_FILE
	# remove unused images
	#docker images --no-trunc | grep '<none>' | awk '{ print $3 }' | xargs -r docker rmi >> $LOG_FILE
	# remove unused volumes
	#docker volume ls -qf dangling=true | xargs -r docker volume rm >> $LOG_FILE
}

## ------ END functions ---------

## ------ START Helper functions ---------
function log()
{
	CUR_DATE=$(date +%Y-%m-%d" "%H:%M:%S)
	echo -e "$CUR_DATE - INFO :: $@"
	if [ -n "$LOG_FILE" ];then
			echo -e "$CUR_DATE - INFO :: $@" >> $LOG_FILE
	fi
}

function logError()
{
	CUR_DATE=$(date +%Y-%m-%d" "%H:%M:%S)
	echo -e "$CUR_DATE - ERROR :: $@"
	if [ -n "$LOG_FILE" ];then
		echo -e "$CUR_DATE - ERROR :: $@" >> $LOG_FILE
	fi
}

function metric()
{
	echo $1 $2 >> $METRICS_FILE
}

## ------ END Helper functions ---------

## ------ START vars def  ---------

NAME=`hostname`
FQDN=`hostname -f`

# Setup relative vars
DATE=$(date +%Y-%m-%d)
TEMP_DIR=$BACKUP_DIR/temp
LOG_DIR=$BACKUP_DIR/logs
LOG_FILE=${LOG_DIR}/${DATE}_backup.log
LOG_RSYNC_FILE=${LOG_DIR}/${DATE}_rsync.log
METRICS_FILE=${LOG_DIR}/${DATE}_metrics.prom

BACKUP_BASE=$BACKUP_DIR/borg
BORG_REPO=$BACKUP_BASE/repo
TIME_START=$(date +%s);

## ------ END vars def ---------

if [[ $EUID -ne 0 ]]; then
  logError "root required"
  exit 1
fi

# we must setup logdir & file b4 everything else
mkdir $LOG_DIR -p 2>/dev/null
touch $LOG_FILE

# Start
log "Starting backup of $FQDN..."

# log start time
metric "backup_time_start{type=\"backup\"}" $(date +%s)


log "Setting up dirs..."
mkdir $BACKUP_BASE -p 2>/dev/null
mkdir $LOG_DIR -p 2>/dev/null
mkdir $TEMP_DIR -p 2>/dev/null
mkdir $BORG_REPO -p 2>/dev/null

rm $LOG_RSYNC_FILE -R 2>/dev/null
touch $LOG_RSYNC_FILE
rm $$METRICS_FILE -R 2>/dev/null
touch $METRICS_FILE

# gather old backup statisitics for metrics file
metric "backup_files_size_last{type=\"backup\"}" $(du -sb ${BACKUP_BASE}/ | cut -f1)
metric "backup_files_count_last{type=\"backup\"}" $(find ${BACKUP_BASE} -type f | wc -l)

##########################
# Setup
##########################
log "Setup for backup..."
metric "backup_time_start{type=\"setup\"}" $(date +%s)
backupSetup
metric "backup_time_completion{type=\"setup\"}" $(date +%s)

##########################
# Files 
##########################
log "Gathering Files..."
metric "backup_time_start{type=\"files\"}" $(date +%s)
backupFiles
metric "backup_time_completion{type=\"files\"}" $(date +%s)

##########################
# Databases 
##########################
log "Dumping database files..."
metric "backup_time_start{type=\"db\"}" $(date +%s)
backupDatabase
metric "backup_time_completion{type=\"db\"}" $(date +%s)


##########################
# Borg 
##########################
log "Starting borg backup..."
metric "backup_time_start{type=\"borg\"}" $(date +%s)

# Borg local settings remote
export BORG_PASSPHRASE=$BORG_PASSPHRASE
export BORG_REPO=$BORG_REPO
export BORG_RSH=""

backupBorg

metric "backup_time_completion{type=\"borg\"}" $(date +%s)


##########################
# Transfer 
##########################
log "Transfering files $BACKUP_BAS to remote..."
metric "backup_time_start{type=\"rsync\"}" $(date +%s)
rsync -aHAXxv --numeric-ids --delete --progress -e "$BACKUP_RSYNC_SSH" -r -P $BACKUP_BASE $BACKUP_RSYNC_REMOTE >> $LOG_RSYNC_FILE
metric "backup_time_completion{type=\"rsync\"}" $(date +%s)

##########################
# Cleanup
##########################
log "Cleanup after backup..."
metric "backup_time_start{type=\"cleanup\"}" $(date +%s)
backupCleanup
metric "backup_time_completion{type=\"cleanup\"}" $(date +%s)

##########################
# Cleanup & Commit
##########################
log "Committing logs & metrics..."

# gather new backup statisitics for metrics file
metric "backup_files_size{type=\"backup\"}" $(du -sb ${BACKUP_BASE}/ | cut -f1)
metric "backup_files_count{type=\"backup\"}" $(find ${BACKUP_BASE} -type f | wc -l)


TIME_END=$(date +%s)
TIME_SECS=$(($TIME_END - $TIME_START))

# commit files
rm ${BACKUP_BASE}/backup.log 2>/dev/null
mv $LOG_FILE ${BACKUP_BASE}/backup.log

rm ${BACKUP_BASE}/rsync.log 2>/dev/null
mv $LOG_RSYNC_FILE ${BACKUP_BASE}/rsync.log

rm ${BACKUP_BASE}/backup.prom 2>/dev/nullm
mv $METRICS_FILE ${BACKUP_BASE}/backup.prom

rsync -aHAXxv --numeric-ids --delete --progress -e "$BACKUP_RSYNC_SSH" -r -P $BACKUP_BASE $BACKUP_RSYNC_REMOTE >> $LOG_FILE

log "Backup $FQDN done after $TIME_SECS..."