# Delete existing modification from file, if it exists
sed -i '/#START_MOD/,/#END_MOD/d' /etc/udev/script/add_usb_storage.sh

# Delete exit from end of the file
sed -i '/^exit$/d' /etc/udev/script/add_usb_storage.sh

# Add call to usb backup script after drive mounts
cat <<'EOF' >> /etc/udev/script/add_usb_storage.sh
#START_MOD
# Run backup script
/etc/udev/script/usb_backup.sh &
exit
#END_MOD
EOF

cat <<'EOF' > /etc/udev/script/usb_backup.sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Kill an existing backup process if running 
# (this can happen if you insert two disks one after the other)
if [ -e /tmp/backup.pid ]; then
        kill $(cat /tmp/backup.pid)
        killall rsync
        sleep 1
fi
echo $$ > /tmp/backup.pid

SD_MOUNTPOINT=/data/UsbDisk1/Volume1
STORE_DIR=/sdcopies
BACKUP_DIR=/fotobackup
PHOTO_DIR="$STORE_DIR"/fotos
CONFIG_DIR="$STORE_DIR"/config
#MEDIA_REGEX=".*\.\(jpg\|gif\|png\|jpeg\|mov\|avi\|wav\|mp3\|aif\|wma\|wmv\|asx\|asf\|m4v\|mp4\|mpg\|3gp\|3g2\|crw\|cr2\|nef\|dng\|mdc\|orf\|sr2\|srf\|mts\|rw2\)"

# Check if an SD card is inserted (always mounted at the same mount point on the Rav Filehub)
check_sdcard() {
        while read device mountpoint fstype remainder; do
        if [ "$mountpoint" == "$SD_MOUNTPOINT" ]; then
                # Get the UUID for the SD card. Create one if it doesn't already exist
                local uuid_file
                uuid_file="$SD_MOUNTPOINT"/sdname.txt
                if [ -e $uuid_file ]; then
                        sd_uuid=`cat $uuid_file`
                else
                        sd_uuid=`cat /proc/sys/kernel/random/uuid`
                        echo "$sd_uuid" > $uuid_file
                fi
                return 1
        fi
        done < /proc/mounts
        return 0
}

# Check if a USB drive is attached which is initialize for storing monitoring data
check_storedrive() {
        while read device mountpoint fstype remainder; do
        if [ ${device:0:7} == "/dev/sd" -a -e "$mountpoint$CONFIG_DIR"/rsync ];then
                # Add the config dir (containing rsync binary) to the PATH
                export PATH="$mountpoint$CONFIG_DIR":$PATH
                store_mountpoint="$mountpoint"
                store_id=$(udevadm info -a -p  $(udevadm info -q path -n ${device:0:8}) | grep -m 1 "ATTRS{serial}" | cut -d'"' -f2)
                return 1
        fi
        done < /proc/mounts
        return 0
}

check_backupdrive() {
        while read device mountpoint fstype remainder; do
        if [ ${device:0:7} == "/dev/sd" -a -e "$mountpoint$BACKUP_DIR" ];then
                backup_mountpoint="$mountpoint"
                local backupid_file
                backup_id_file="$mountpoint$BACKUP_DIR"/.backup_id
                if [ -e $backup_id_file ]; then
                        backup_id=`cat $backup_id_file`
                elif [ $storedrive -eq 1 ]; then
                        backup_id="$store_id"
                        echo "$backup_id" > $backup_id_file
                fi
                return 1
        fi
        done < /proc/mounts
        return 0
}

# If no SD card is inserted, just exit.
check_sdcard
sdcard=$?

check_storedrive
storedrive=$?

check_backupdrive
backupdrive=$?

# If both a valid store drive and SD card are mounted,
# copy the SD card contents to the store drive
if [ $sdcard -eq 1 -a $storedrive -eq 1 ];then
        # Organize the photos in a folder for each SD card by UUID,
        target_dir="$store_mountpoint$PHOTO_DIR"/"$sd_uuid"
        mkdir -p $target_dir
        mkdir -p "$STORE_DIR"/log
        # Copy the files from the sd card to the target dir, 
        # Uses filename and size to check for duplicates
        echo "$(date): Copying SD card to $target_dir" >> "$STORE_DIR"/log/usb_add_info
        rsync -vrm --size-only --log-file /tmp/rsync_log --exclude ".?*" \ 
                "$SD_MOUNTPOINT"/DCIM \ 
                "$SD_MOUNTPOINT"/PRIVATE \
                "$SD_MOUNTPOINT"/MP_ROOT \
                "$SD_MOUNTPOINT"/AVF_INFO \
                "$target_dir"
fi

# If both a valid store drive and a matching backup drive are attached,
# backup the store drive to the backup drive
if [ $storedrive -eq 1 -a $backupdrive -eq 1 -a "$backup_id" == "$store_id" ]; then
        source_dir="$store_mountpoint$STORE_DIR"
        target_dir="$backup_mountpoint$BACKUP_DIR"
        partial_dir="$store_mountpoint$PHOTO_DIR"/incoming/.partial
        echo "Backing up data store to $target_dir" >> "$STORE_DIR"/log/usb_add_info
        rsync -vrm --size-only --delete-during --exclude ".?*" --partial-dir "$partial_dir" --exclude "swapfile" --log-file /tmp/rsync_log "$source_dir"/ "$target_dir"
        if  [ $? -eq 0 ]; then
                echo "$(date): Backup complete" >> "$STORE_DIR"/log/usb_add_info
        else
                echo "$(date): Backup failed" >> "$STORE_DIR"/log/usb_add_info
        fi
fi

# Write memory buffer to disk
sync

rm /tmp/backup.pid
exit
EOF

# Make executable
chmod +x /etc/udev/script/usb_backup.sh
