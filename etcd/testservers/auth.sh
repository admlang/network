#!/usr/bin/env bash
# Starts an etcd with authentication in docker on 127.0.0.1:2389: user root
# (password "secret", role root) and user reader (password "reader", role
# adm-test-read: read access to /adm-test/). Tokens live two seconds, so the
# suite sees one expire. Prints the variable the suite reads.
set -euo pipefail

name=${ETCD_AUTH_NAME:-adm-test-etcd-auth}
image=${ETCD_IMAGE:-quay.io/coreos/etcd:v3.6.0}
port=2389

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p "127.0.0.1:$port:2379" "$image" etcd \
	--advertise-client-urls http://0.0.0.0:2379 --listen-client-urls http://0.0.0.0:2379 \
	--auth-token simple --auth-token-ttl 2 >/dev/null

ctl() { docker exec "$name" etcdctl "$@" >/dev/null; }
for _ in $(seq 30); do ctl endpoint health 2>/dev/null && break; sleep 1; done
ctl user add root:secret
ctl user grant-role root root
ctl role add adm-test-read
ctl role grant-permission adm-test-read read /adm-test/ --prefix=true
ctl user add reader:reader
ctl user grant-role reader adm-test-read
ctl auth enable
echo "ADM_TEST_ETCD_AUTH=root:secret@127.0.0.1:$port"
