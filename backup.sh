#!/bin/bash

fs_backup_location=""
db_backup_location=""
s3_endpoint=" https://s3.cloud.cmctelecom.vn"
s3_bucket="s3://phongcachxanh.vn-backups"

### Send email or error function
# usage send_errormail "message"
send_errormail () {
    # curl https://api.sendgrid.com/api/mail.send.json \
    # -F to= -F toname=test -F subject="Autobackup failed" \
    # -F text="$1" \
    # -F from= -F api_user= -F api_key=

    mail -s "Autobackup Failed!" alice@sanusi.id < $1
}

### Cheking disk space
# usage: check_disk folder
# return number is percent disk usage
check_disk () {
    disk_usage=$(df $1 | grep "/" | awk {'print $5'} | sed -e 's|%||'  )
    echo $disk_usage
}

### Backup Function
# usage: backup_function "type(db or fs)" "backup_destination(folder)" "backup_source(folder or db name if db type)" 
backup_function () {
    # Check disk, abort if disk morethan 80% used
    # comment this if want disable disk check
    disk_usage="$(check_disk $2)"
    if [[ $disk_usage -ge 81 ]]
    then
        send_errormail "Disk space warning!\nDisk space usage is more than 80%! Backup aborted! Please make more space!"
        exit 1
    fi

    # if backup type Database
    if [ $1 == "db" ]
    then
        dbname="$3_$(date +%Y-%m-%d).gz"
        check_db=$(sudo -u postgres psql -l | grep "$3")
        if [ -z $check_db]
        then
            send_errormail "Backup failed, database $3 not found!!"
            return 1
        else
            sudo -u postgre pg_dump $3 | gzip > $2/$dbname
            if [ $? -ne 0 ]
            then
                send_errormail "Backup failed! Failed to backup database $3"
                return 1
            fi
        fi
    elif [ $1 == "fs"]
    then
        dirname=$(basename $3)
        fsname="$dirname-$(date +%Y-%m-%d).tar.gz"
        sudo tar zcf $2/fsname $3
        if [ $? -ne 0]
        then
            send_errormail "Backup failed! Failed to backup filestore $3"
            return 1
        fi
    else
        echo ""
}

delete_s3_old_backup() {
    aws s3 --endpoint-url $s3_endpoint ls $s3_bucket | grep " DIR " -v | while read -r line;
    do
        createDate=$(echo $line | awk {'print $1" "$2'})
        createDate=$(date -d "$createDate" +%s)
        olderThan=$(date -d "$2 day ago" +%s)
        if [[ $createDate -lt $olderThan ]]
        then
            fileName=`echo $line | awk {'print $4'}`
            if [[ $fileName != "" ]]
            then
                printf 'Deleting "%s"\n' $fileName
                aws s3 --endpoint-url $s3_endpoint rm $s3_bucket/$1
            fi
        fi
    done    
}
