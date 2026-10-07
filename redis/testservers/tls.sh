#!/bin/sh
# A Redis that takes TLS on 127.0.0.1:56380 and a Unix socket, for the
# tests gated on ADM_TEST_REDIS_TLS and ADM_TEST_REDIS_SOCKET.
# Usage: tls.sh <folder for the certificates and the socket>
#
#   ADM_TEST_REDIS_TLS=127.0.0.1:56380 ADM_TEST_REDIS_CERTS=<folder> \
#   ADM_TEST_REDIS_SOCKET=<folder>/redis.sock adm test network/redis
set -e
dir=${1:?usage: tls.sh <folder for the certificates and the socket>}
mkdir -p "$dir" && cd "$dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=adm-test-ca" -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile server.ext -out server.pem 2>/dev/null
chmod 644 *.key
chmod 777 .
docker rm -f adm-test-redis-tls >/dev/null 2>&1 || true
docker run -d --name adm-test-redis-tls -p 127.0.0.1:56380:56380 -v "$dir":/certs:z redis:latest \
  redis-server --port 0 --tls-port 56380 --tls-cert-file /certs/server.pem --tls-key-file /certs/server.key \
  --tls-ca-cert-file /certs/ca.pem --tls-auth-clients no \
  --unixsocket /certs/redis.sock --unixsocketperm 777 --save "" >/dev/null
echo "started adm-test-redis-tls on 127.0.0.1:56380 and $dir/redis.sock"
