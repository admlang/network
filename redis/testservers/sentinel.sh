#!/bin/sh
# A master (57100), two replicas (57101, 57102) and three sentinels
# (57200-57202) watching it as "mymaster", in one container (host network).
rm -rf /data/s && mkdir -p /data/s && cd /data/s
redis-server --port 57100 --bind 127.0.0.1 --save "" --appendonly no --daemonize yes --logfile /data/s/m.log --dir /data/s
for p in 57101 57102; do
  redis-server --port $p --bind 127.0.0.1 --replicaof 127.0.0.1 57100 --save "" --appendonly no --daemonize yes --logfile /data/s/$p.log --dir /data/s
done
for p in 57200 57201 57202; do
  printf 'port %s\nbind 127.0.0.1\nsentinel monitor mymaster 127.0.0.1 57100 2\nsentinel down-after-milliseconds mymaster 1500\nsentinel failover-timeout mymaster 6000\nsentinel parallel-syncs mymaster 1\n' $p > s$p.conf
  redis-server s$p.conf --sentinel --daemonize yes --logfile /data/s/s$p.log
done
tail -f /dev/null
