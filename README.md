# postgres-s3-backup

Lightweight PostgreSQL backups to Amazon S3 for Docker Compose deployments.

Designed for small PostgreSQL installations running on AWS EC2 where you want simple, low-cost backups without running a separate backup service.

## Features

- **Multi-database support** — automatically discovers and backs up all databases
- **PostgreSQL globals** — backs up roles and other global objects
- **Validation** — validates every dump with `pg_restore`
- **S3 verification** — verifies uploaded objects before marking a backup complete
- **Daily + intraday backups** — separates long-term and temporary recovery points
- **Automatic cleanup** — removes previous intraday backups after a successful daily backup
- **EC2 IAM support** — no AWS access keys need to be stored in the container
- **Low resource usage** — backup container runs only when needed
- **Systemd scheduling** — runs automatically every 6 hours

## Backup Schedule

The included systemd timer runs at:

| Time (UTC) | Type |
|---|---|
| 00:00 | Daily |
| 06:00 | Intraday |
| 12:00 | Intraday |
| 18:00 | Intraday |

Daily backups can be retained using an S3 lifecycle policy.

Intraday backups are automatically removed after the next successful daily backup.

## S3 Structure

Backups are organized as:

    production/
    ├── daily/
    │   └── <timestamp>/
    │       ├── globals.sql
    │       ├── database-a.dump
    │       ├── database-b.dump
    │       ├── manifest.json
    │       └── COMPLETE
    │
    └── intraday/
        └── <timestamp>/
            └── ...

The `COMPLETE` marker is uploaded only after the backup has been created, validated, uploaded, and verified.

## Configuration

Create a `.env` file:

    POSTGRES_PASSWORD=change-me
    POSTGRES_DB=app
    POSTGRES_BACKUP_BUCKET=your-backup-bucket

The EC2 instance should have an IAM role with permission to read/write the backup bucket.

No AWS access keys need to be stored in `.env` or mounted into the container.

## Run a Backup

Build the backup image:

    docker compose build postgres-backup

Run a backup manually:

    docker compose run --rm postgres-backup

## Enable Automatic Backups

Copy the included systemd files:

    sudo cp systemd/postgres-backup.service /etc/systemd/system/
    sudo cp systemd/postgres-backup.timer /etc/systemd/system/

Update the `WorkingDirectory` in `postgres-backup.service` to point to your Docker Compose project.

Then enable the timer:

    sudo systemctl daemon-reload
    sudo systemctl enable --now postgres-backup.timer

Check the schedule:

    systemctl list-timers postgres-backup.timer

Check backup logs:

    journalctl -u postgres-backup.service -n 100 --no-pager

## Important

A backup is only useful if it can be restored.

Always perform a restore test against a temporary PostgreSQL instance before relying on this setup for production.