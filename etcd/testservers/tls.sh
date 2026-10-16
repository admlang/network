#!/usr/bin/env bash
# Starts an etcd in docker on 127.0.0.1:2399 that takes TLS only and asks for
# a client certificate signed by its own CA. Writes ca.pem, client.pem and
# client.key to the folder given and prints the variables the suite reads.
# Usage: tls.sh <folder for the certificates>
set -euo pipefail

dir=${1:?usage: tls.sh <folder for the certificates>}
name=${ETCD_TLS_NAME:-adm-test-etcd-tls}
image=${ETCD_IMAGE:-quay.io/coreos/etcd:v3.6.0}
port=2399
mkdir -p "$dir" && cd "$dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=adm-test-ca" -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile server.ext -out server.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=adm-test" -keyout client.key -out client.csr 2>/dev/null
printf 'extendedKeyUsage=clientAuth\n' > client.ext
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile client.ext -out client.pem 2>/dev/null
chmod 644 ./*.key

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p "127.0.0.1:$port:2379" -v "$PWD":/certs:z "$image" etcd \
	--advertise-client-urls https://localhost:2379 --listen-client-urls https://0.0.0.0:2379 \
	--cert-file /certs/server.pem --key-file /certs/server.key \
	--client-cert-auth --trusted-ca-file /certs/ca.pem >/dev/null
sleep 2
echo "ADM_TEST_ETCD_TLS=127.0.0.1:$port ADM_TEST_ETCD_CERTS=$PWD"
