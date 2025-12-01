FROM debian
# pin version to 1.4.0-5
RUN apt-get update && apt-get install -y \
    borgbackup=1.4.0-5  \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /backup

CMD [tail -f /dev/null]
