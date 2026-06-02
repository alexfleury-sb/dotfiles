#!/bin/bash

# Some helpers and error handling.
info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }
trap "echo $( date ) Backup interrupted >&2; exit 2" INT TERM

# Close if borg or rclone is running.
if pgrep "borg" > /dev/null
then
    Info "Backup already running, exiting"
    exit
    exit
fi

# Read borg passphrase.
export BORG_PASSPHRASE=$(op read op://Employee/BorgBackup/password)

# Setting this, so the repo does not need to be given on the commandline.
export BORG_REPO="$HOME/Backups"
# This is the location you want to send the BORG_REPO to.
export CLOUD_DEST=$(op read op://Employee/BorgBackup/password)

info "Starting backup..."

# Backup the most important directories into an archive named after
# the machine this script is currently running on:

borg create                     \
    --verbose                   \
    --filter AMEx               \
    --files-cache=mtime,size    \
    --list                      \
    --stats                     \
    --show-rc                   \
    --compression lzma,9        \
    --exclude-caches            \
    --exclude "*/.DS_Store"     \
    --exclude "*/*.h5"          \
                                \
    ::"{hostname}-{now}"        \
    $HOME/Work                  \
    $HOME/Zotero

backup_exit=$?

info "Pruning repository..."

# Use the `prune` subcommand to maintain d daily, w weekly and m monthly
# archives of THIS machine. The "{hostname}-" prefix is very important to
# limit prune"s operation to this machine"s archives and not apply to
# other machines" archives also:

borg prune                  \
    --list                  \
    --prefix "{hostname}-"  \
    --show-rc               \
    --keep-daily    7       \
    --keep-weekly   4       \
    --keep-monthly  6

prune_exit=$?

# Use highest exit code as global exit code.
global_exit=$(( backup_exit > prune_exit ? backup_exit : prune_exit ))
unset BORG_PASSPHRASE

# Cloud sync.
if [[ ( ${global_exit} -eq 0 ) ]]; then
    info "Bucket sync has started..."
    gcloud storage rsync -r $BORG_REPO $CLOUD_DEST
    info "Bucket sync completed."
elif [[ ${global_exit} -eq 0 ]]; then
    info "Backup, Prune and/or Compact finished sucessfully without cloud synchronization."
else
    info "Backup, Prune and/or Compact finished with an error."
fi

unset BORG_REPO
unset CLOUD_DEST

exit ${global_exit}
