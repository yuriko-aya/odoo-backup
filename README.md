# Odoo Backup

Autobackup script for Odoo  
Backup Odoo Database and Filestore

# Requirement

- `gsutil` from Google Cloud SDK for Google Cloud Storage and configured by root user
- `aws` from aws-cli for Amazon Web Service S3
- `mail` from mailutils

# Feature

Create 14 regular backups. 7 (seven) daily backups for a week, 4 (four) weekly backups for a month, and 3 (three) monthly backups for 3 months.

## Storage Save

This script won't backup if the space of the backup destination is less than 20% available, even if using cloud only backup. This is safety measure if the backup is so big that will cause system halt because of disk full

## Three backup types

### Full sync `backup_type="sync"`

Full sync will save **ALL** 14 backups both on site and cloud storage. All backup action (create, and delete) will be done only on local machine, and then sent to the cloud using sync for AWS S3 and rsync for GCS.

### Partial sync `backup_type="partial"`

Partial sync will save all 14 backups on the cloud **BUT** only few on site. The `local_age` variable define how old on site backup is kept before deleted. This can be used when the disk space is limited but stll want to use on site backups.

### Cloud only backup `backup_type="cloud"`
Cloud only backup won't create any on site backup. All 14 backups will only be saved on the cloud. Once today's backup is sent to the cloud, on site back up will be deleted. This is for server with very limited disk available.

## Mail Notification

Setup mail notification for sendgrid is available using sendgrid send api

## Logging

Log is saved in `/var/log/backup/backup_script.log`

# Supported Storage Provider

- Google Cloud Storage 'gs'
- Amazon Web Service S3 's3'
