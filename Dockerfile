FROM postgres:17.9

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       awscli \
       jq \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY backup.sh /usr/local/bin/backup.sh

RUN chmod +x /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/backup.sh"]