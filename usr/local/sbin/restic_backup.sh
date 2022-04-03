#!/usr/bin/env bash
# Make backup my system with restic to Backblaze B2.
# This script is typically run by: /etc/systemd/system/restic-backup.{service,timer}

# Exit on failure, pipe failure
set -e -o pipefail

# Clean up lock if we are killed.
# If killed by systemd, like $(systemctl stop restic), then it kills the whole cgroup and all it's subprocesses.
# However if we kill this script ourselves, we need this trap that kills all subprocesses manually.
exit_hook() {
	echo "In exit_hook(), being killed" >&2
	jobs -p | xargs kill
	restic unlock
}
trap exit_hook INT TERM

# Set all environment variables
source /etc/restic/env.sh

# How many backups to keep.
RETENTION_DAYS=14
RETENTION_WEEKS=16
RETENTION_MONTHS=18
RETENTION_YEARS=3

if [ -z "$BACKUP_PATHS" ]
then 
	echo "BACKUP_PATHS is empty or not set"
	exit 1
fi

[ -d /mnt/media ] && BACKUP_PATHS+=" /mnt/media"
BACKUP_EXCLUDES="--exclude-file /etc/restic/backup_exclude"
for dir in /home/*
do
	if [ -f "$dir/.backup_exclude" ]
	then
		BACKUP_EXCLUDES+=" --exclude-file $dir/.backup_exclude"
	fi
done

BACKUP_TAG=systemd.timer


# How many network connections to set up to B2. Default is 5.
AZURE_CONNECTIONS=50

# NOTE start all commands in background and wait for them to finish.
# Reason: bash ignores any signals while child process is executing and thus my trap exit hook is not triggered.
# However if put in subprocesses, wait(1) waits until the process finishes OR signal is received.
# Reference: https://unix.stackexchange.com/questions/146756/forward-sigterm-to-child-in-bash

# Remove locks from other stale processes to keep the automated backup running.
restic unlock &
wait $!

# Do the backup!
# See restic-backup(1) or http://restic.readthedocs.io/en/latest/040_backup.html
# --one-file-system makes sure we only backup exactly those mounted file systems specified in $BACKUP_PATHS, and thus not directories like /dev, /sys etc.
# --tag lets us reference these backups later when doing restic-forget.
restic backup \
	--verbose \
	--one-file-system \
	--tag $BACKUP_TAG \
	--option azure.connections=$AZURE_CONNECTIONS \
	$BACKUP_EXCLUDES \
	$BACKUP_PATHS &
wait $!

su - xobb -c "notify-send --urgency=low --app-name=restic --icon=/home/xobb/Pictures/restic.png --category=BACKUP 'Backup Snaptshot Created' 'Your Documents folder has been backed up on the cloud at $(date)'"


# Dereference and delete/prune old backups.
# See restic-forget(1) or http://restic.readthedocs.io/en/latest/060_forget.html
# --group-by only the tag and path, and not by hostname. This is because I create a B2 Bucket per host, and if this hostname accidentially change some time, there would now be multiple backup sets.
restic forget \
	--verbose \
	--tag $BACKUP_TAG \
	--option azure.connections=$AZURE_CONNECTIONS \
        --prune \
	--group-by "paths,tags" \
	--keep-daily $RETENTION_DAYS \
	--keep-weekly $RETENTION_WEEKS \
	--keep-monthly $RETENTION_MONTHS \
	--keep-yearly $RETENTION_YEARS &
wait $!

# Check repository for errors.
# NOTE this takes much time (and data transfer from remote repo?), do this in a separate systemd.timer which is run less often.
#restic check &
#wait $!

echo "Backup & cleaning is done."

