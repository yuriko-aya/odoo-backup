#!/bin/bash

############################################################################ Bakcup Variables
### Local location variable
db_name="odoo13"
odoo_data_dir="/opt/odoo/.local/share/Odoo" # must be same with data_dir in odoo config
backup_location="/opt/backup"

fs_location="$odoo_data_dir/filestore/$db_name"
mkdir -p $backup_location

## Google Cloud Storage Config
gs_bucket="gs://"

### Advanced config
## Backup type:
# sync (default): full backup on local (7 daily, 4 weekly, and 3 monthly) and sync it to cloud
# partial: full backup on the cloud but only few on local depends to local_age variable
# cloud: cloud only backup, no local backup.
backup_type="partial"
local_age="7"       # in days, required only if backup_type="partial"

## PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH

################################################################################## Logging
# create logfile if not exist
logfile="/var/log/backup/gs_backup.log"
if [ ! -e $logfile ]
then
    mkdir -p "/var/log/backup/"
    touch $logfile
fi

## add timestamp to log
add_date() {
    while IFS='' read -r line
    do
        echo "$(date): $line" >> $logfile
    done
}

exec 1> >(add_date) 2>&1

############################################################################# Send email on error function
# usage send_errormail "message"
send_errormail () {
    log_message="$(tail -n 30 $logfile)"
    # curl https://api.sendgrid.com/api/mail.send.json \
    # -F to= -F toname= -F subject="Autobackup failed" \
    # -F text="$1 \nLog file (latest 30 lines):\n $log_message" \
    # -F from= -F api_user= -F api_key=

    echo "$1 \nLog file (latest 30 lines):\n $log_message" | mail -s "Autobackup Failed!" root@localhost
}

############################################################################# Precheck for available disk space
# Abort backup if disk space less than 20%
# usage: check_disk folder
# return number is percent disk usage
check_disk () {
    disk_usage="$(df $1 | grep "/" | awk {'print $5'} | sed -e 's|%||'  )"
    echo $disk_usage
}

# Check disk, abort if disk morethan 80% used
# comment this if want disable disk check
disk_usage="$(check_disk $backup_location)"
if [[ $disk_usage -ge 81 ]]
then
    echo "Disk space warning!\nDisk space usage is more than 80%! Backup aborted! Please make more space!"
    send_errormail "Disk space warning!\nDisk space usage is more than 80%! Backup aborted! Please make more space!"
    exit 1
fi

################################################################################## Functions for backup

### Delete old backup on Google Cloud Storage
# usage: delete_gs_old_backup folder_to_cleanup age(days)
# example: delete_gs_old_backup db/daily 30
delete_gs_old_backup() {
    gsutil ls -l $gs_bucket/$1 | grep "TOTAL" -v | while read -r line;
    do
        create_date=$(echo $line | awk {'print $2'})
        create_date=$(date -d "$create_date" +%s)
        older_than=$(date -d "$2 day ago" +%s)
        if [[ $create_date -lt $older_than ]]
        then
            file_name=`echo $line | awk {'print $3'}`
            if [[ $file_name != "" ]]
            then
                printf 'Deleting "%s"\n' $file_name
                gsutil rm $file_name
            fi
        fi
    done
}

### Delete old backup on local storage
# usage: delete_local_old_backup folder_to_cleanup age(days)
# example: delete_local_old_backup /opt/backup/db/weekly 30
delete_local_old_backup() {
    echo "Deleting $2 days old backup from $1"
    find "$1" -type f -mtime +$2 ! -name "*.sh" -delete
}

## Upload compressed backup to cloud function
# usage cloud_upload file destination_object(db/daily, db/monthly, etc) age_to_delete
cloud_upload() {
    # Upload to GS
    echo "Uploading $1 to $gs_bucket/$2/"
    gsutil cp $1 $gs_bucket/$2/
    if [[ $? -ne 0 ]]
    then
        echo "Failed to upload backup to Google Cloud Storage\nFile: $1\nDestination: $2"
        send_errormail "Failed to upload backup to Google Cloud Storage\nFile: $1\nDestination: $2"
        return 1
    fi
    echo "Deleting $3 days old backup from $gs_bucket/$2"
    delete_gs_old_backup $2 $3
}

cloud_sync() {
    echo "Syncronize $backup_location/$1 to $gs_bucket/$1/"
    gsutil -m rsync -d -r $backup_location/$1 $gs_bucket/$1/
    if [[ $? -ne 0 ]]
    then
        echo "Failed syncronize $backup_location/$1 to Google Cloud Storage"
        send_errormail "Failed syncronize $backup_location/$1 to Google Cloud Storage"
        return 1
    fi
}

### Backup Function
# usage: backup_function "type(db or fs)" "backup_location(folder)" "backup_source(folder or db name if db type)"
backup_function () {
    # if backup type Database
    today_day=$(date +%A)
    today_date=$(date +%d)
    if [ "$1" = "db" ]
    then
        dbname="$3_$(date +%Y-%m-%d).gz"
        echo "Backuping databse $dbname to $2"
        sudo -u postgres pg_dump $3 | gzip > $2/$dbname
        if [ $? -ne 0 ]
        then
            echo "Backup failed! Failed to backup database $3"
            send_errormail "Backup failed! Failed to backup database $3"
            return 1
        fi
        echo "Saving backup to daily backup directory"
        mv "$2/$dbname" "$2/db/daily/"
        if [ "$backup_type" = "sync" ]
        then
            echo "Deleting 7 days old backup from daily backup"
            delete_local_old_backup "$2/db/daily/" 7
            if [ "$today_day" = "Monday" ]
            then
                echo "Saving backup to weekly backup directory"
                cp "$2/db/daily/$dbname" "$2/db/weekly/"
                echo "Deleteing 30 days old backup from weekly backup directory"
                delete_local_old_backup "$2/db/weekly/" 28
            fi
            if [ "$today_date" = "28" ]
            then
                echo "Saving backup to monthly backup directory"
                cp "$2/db/daily/$dbname" "$2/db/monthly/"
                echo "Deleting 90 days old backup from monthly backup directory"
                delete_local_old_backup "$2/db/monthly/" 89
            fi
            cloud_sync "db"
        else
            cloud_upload "$2/db/daily/$dbname" "db/daily" 7
            if [ "$today_day" = "Monday" ]
            then
                cp "$2/db/daily/$dbname" "$2/db/weekly/"
                cloud_upload "$2/db/weekly/$dbname" "db/weekly" 28
            fi
            if [ "$today_date" = "28" ]
            then
                cp "$2/db/daily/$dbname" "$2/db/monthly/"
                cloud_upload "$2/db/monthly/$dbname" "db/monthly" 89
            fi
            if [ "$backup_type" = "partial" ]
            then
                delete_local_old_backup "$2" "$local_age"
            else
                echo "Deleting all backup from local($2)"
                find "$2" -type f ! -name "*.sh" -delete
            fi
        fi
    elif [ "$1" = "fs" ]
    then
        fsname="$db_name-$(date +%Y-%m-%d).tar.gz"
        echo "Backuping filestore $db_name to $2"
        sudo tar zcf "$2/$fsname" "$3"
        if [[ $? -ne 0 ]]
        then
            echo "Backup failed! Failed to backup filestore $3"
            send_errormail "Backup failed! Failed to backup filestore $3"
            return 1
        fi
        echo "Saving backup to daily backup directory"
        mv "$2/$fsname" "$2/fs/daily/"
        if [ "$backup_type" = "sync" ]
        then
            echo "Deleting 7 days old backup from daily backup"
            delete_local_old_backup "$2/fs/daily/" 7
            if [ "$today_day" = "Monday" ]
            then
                echo "Saving backup to weekly backup directory"
                cp "$2/fs/daily/$fsname" "$2/fs/weekly/"
                echo "Deleteing 30 days old backup from weekly backup directory"
                delete_local_old_backup "$2/fs/weekly/" 28
            fi
            if [ "$today_date" = "28" ]
            then
                echo "Saving backup to monthly backup directory"
                cp "$2/fs/daily/$fsname" "$2/fs/monthly/"
                echo "Deleting 90 days old backup from monthly backup directory"
                delete_local_old_backup "$2/fs/monthly/" 89
            fi
            cloud_sync "fs"
        else
            cloud_upload "$2/fs/daily/$fsname" "fs/daily" 7
            if [ "$today_day" = "Monday" ]
            then
                cp "$2/fs/daily/$fsname" "$2/fs/weekly/"
                cloud_upload "$2/fs/weekly/$fsname" "fs/weekly" 28
            fi
            if [ "$today_date" = "28" ]
            then
                cp "$2/fs/daily/$fsname" "$2/fs/monthly/"
                cloud_upload "$2/fs/monthly/$fsname" "fs/monthly" 89
            fi
            if [ "$backup_type" = "partial" ]
            then
                delete_local_old_backup "$2" "$local_age"
            else
                echo "Deleting all backup from local($2)"
                find "$2" -type f ! -name "*.sh" -delete
            fi
        fi
    else
        echo "Error! Wrong type!"
        exit 1
    fi
}

################################################################################# Start backup action

## Create directory if not exist, just in case
mkdir -p $backup_location/{db,fs}/{daily,weekly,monthly}

## Check database, exit if not exists
# if db not found then there's no point to try to backup filestore
check_db="$(sudo -u postgres psql -l | grep "$db_name" | awk {'print $1'})"
if [ -z $check_db ]
then
    echo "Backup failed, database $db_name not found!! Aborting"
    send_errormail "Backup failed, database $db_name not found!! Aborting"
    exit 1
fi

## BACKUP!!!!

backup_function db $backup_location $db_name

# if backup database error then no backup filestore
# exit if backup db error
if [[ $? -ne 0 ]]
then
    exit 1
fi

# backup databse success, then backup filestore
backup_function fs $backup_location $fs_location
