#!/usr/bin/env bash
set -Eeuo pipefail

BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
PREFIX="${S3_PREFIX:-production}"

TIMESTAMP="$(date -u +'%Y-%m-%dT%H-%M-%SZ')"
HOUR="$(date -u +'%H')"

# Midnight backup = daily; all others = intraday.
if [[ "$HOUR" == "00" ]]; then
    BACKUP_TYPE="daily"
else
    BACKUP_TYPE="intraday"
fi

S3_PATH="${PREFIX}/${BACKUP_TYPE}/${TIMESTAMP}"
WORKDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== PostgreSQL backup starting ==="
echo "Type: ${BACKUP_TYPE}"
echo "Destination: s3://${BUCKET}/${S3_PATH}/"


echo "Backing up PostgreSQL globals..."

pg_dumpall \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --globals-only \
    > "$WORKDIR/globals.sql"

test -s "$WORKDIR/globals.sql"

mapfile -t DATABASES < <(
    psql \
        --host="$PGHOST" \
        --port="$PGPORT" \
        --username="$PGUSER" \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="
            SELECT datname
            FROM pg_database
            WHERE datallowconn = true
              AND datistemplate = false
            ORDER BY datname;
        "
)

if [[ ${#DATABASES[@]} -eq 0 ]]; then
    echo "ERROR: No databases discovered."
    exit 1
fi

echo "Found databases:"
printf ' - %s\n' "${DATABASES[@]}"


for DB in "${DATABASES[@]}"; do

    echo "Backing up: $DB"

    FILE="$WORKDIR/${DB}.dump"

    pg_dump \
        --host="$PGHOST" \
        --port="$PGPORT" \
        --username="$PGUSER" \
        --dbname="$DB" \
        --format=custom \
        --compress=6 \
        --file="$FILE"

    test -s "$FILE"

    # Verify pg_restore can read the archive.
    pg_restore --list "$FILE" >/dev/null

    echo "Validated: $DB"
done


{
    echo "{"
    echo "  \"created_at\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\","
    echo "  \"backup_type\": \"$BACKUP_TYPE\","
    echo "  \"postgres_version\": \"$(pg_dump --version | sed 's/"/\\"/g')\","
    echo "  \"databases\": ["

    for ((i=0; i<${#DATABASES[@]}; i++)); do
        if (( i + 1 == ${#DATABASES[@]} )); then
            echo "    \"${DATABASES[$i]}\""
        else
            echo "    \"${DATABASES[$i]}\","
        fi
    done

    echo "  ]"
    echo "}"
} > "$WORKDIR/manifest.json"


echo "Uploading backup..."

for FILE in "$WORKDIR"/*; do
    BASENAME="$(basename "$FILE")"

    aws s3 cp \
        "$FILE" \
        "s3://${BUCKET}/${S3_PATH}/${BASENAME}" \
        --only-show-errors
done

echo "Verifying S3 objects..."

for FILE in "$WORKDIR"/*; do
    BASENAME="$(basename "$FILE")"

    aws s3api head-object \
        --bucket "$BUCKET" \
        --key "${S3_PATH}/${BASENAME}" \
        >/dev/null
done


echo "complete" > "$WORKDIR/COMPLETE"

aws s3 cp \
    "$WORKDIR/COMPLETE" \
    "s3://${BUCKET}/${S3_PATH}/COMPLETE" \
    --only-show-errors

echo
echo "=== BACKUP SUCCESSFUL ==="
echo "s3://${BUCKET}/${S3_PATH}/"

# Verify COMPLETE marker exists
aws s3api head-object \
    --bucket "$BUCKET" \
    --key "${S3_PATH}/COMPLETE" \
    >/dev/null


if [[ "$BACKUP_TYPE" == "daily" ]]; then

    YESTERDAY="$(date -u -d 'yesterday' +'%Y-%m-%d')"

    echo "Daily backup completed successfully."
    echo "Cleaning intraday backups from: ${YESTERDAY}"

    aws s3 rm \
        "s3://${BUCKET}/${PREFIX}/intraday/${YESTERDAY}" \
        --recursive \
        --only-show-errors

    echo "Previous intraday backups cleaned."
fi