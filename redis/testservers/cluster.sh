#!/bin/sh
# Six Redis nodes on 127.0.0.1:42100-42105 in one container (host network),
# three masters with a replica each.
rm -rf /data/c && mkdir -p /data/c && cd /data/c
for p in 42100 42101 42102 42103 42104 42105; do
  mkdir -p $p
  redis-server --port $p --bind 127.0.0.1 --cluster-enabled yes --cluster-config-file nodes.conf \
    --cluster-node-timeout 2000 --appendonly no --save "" --dir /data/c/$p --daemonize yes --logfile /data/c/$p/log
done
sleep 1
redis-cli --cluster create 127.0.0.1:42100 127.0.0.1:42101 127.0.0.1:42102 127.0.0.1:42103 127.0.0.1:42104 127.0.0.1:42105 --cluster-replicas 1 --cluster-yes
tail -f /dev/null
