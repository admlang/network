#!/usr/bin/env bash
# Starts a three-member etcd cluster in docker on the host network: clients
# on 127.0.0.1:2481, 2482 and 2483, peers on 2491, 2492 and 2493. Prints the
# variable the suite reads.
set -euo pipefail

image=${ETCD_IMAGE:-quay.io/coreos/etcd:v3.6.0}
initial="m1=http://127.0.0.1:2491,m2=http://127.0.0.1:2492,m3=http://127.0.0.1:2493"
for i in 1 2 3; do
	docker rm -f "adm-test-etcd-m$i" >/dev/null 2>&1 || true
	docker run -d --name "adm-test-etcd-m$i" --network host "$image" etcd --name "m$i" \
		--listen-client-urls "http://127.0.0.1:248$i" --advertise-client-urls "http://127.0.0.1:248$i" \
		--listen-peer-urls "http://127.0.0.1:249$i" --initial-advertise-peer-urls "http://127.0.0.1:249$i" \
		--initial-cluster "$initial" --initial-cluster-state new --initial-cluster-token adm-test >/dev/null
done
for _ in $(seq 30); do
	docker exec adm-test-etcd-m1 etcdctl --endpoints 127.0.0.1:2481,127.0.0.1:2482,127.0.0.1:2483 endpoint health >/dev/null 2>&1 && break
	sleep 1
done
echo "ADM_TEST_ETCD_CLUSTER=127.0.0.1:2481,127.0.0.1:2482,127.0.0.1:2483"
