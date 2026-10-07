#!/bin/sh
# A Kafka that takes TLS on 127.0.0.1:59292, for the test gated on
# ADM_TEST_KAFKA_TLS. Usage: tls.sh <folder for the certificates>
#
#   ADM_TEST_KAFKA_TLS=127.0.0.1:59292 ADM_TEST_KAFKA_CERTS=<folder> adm test network/kafka
set -e
dir=${1:?usage: tls.sh <folder for the certificates>}
mkdir -p "$dir" && cd "$dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=adm-test-ca" -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile server.ext -out server.pem 2>/dev/null
openssl pkcs12 -export -in server.pem -inkey server.key -certfile ca.pem -name broker -passout pass:adm-test -out server.p12
printf 'adm-test' > password
chmod 644 server.p12 password
docker rm -f adm-test-kafka-tls >/dev/null 2>&1 || true
docker run -d --name adm-test-kafka-tls --network host -v "$dir":/etc/kafka/secrets:ro,z \
  -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=SSL://127.0.0.1:59292,CONTROLLER://127.0.0.1:59293,PLAINTEXT://127.0.0.1:59294 \
  -e KAFKA_ADVERTISED_LISTENERS=SSL://127.0.0.1:59292,PLAINTEXT://127.0.0.1:59294 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER -e KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,SSL:SSL \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@127.0.0.1:59293 \
  -e KAFKA_SSL_KEYSTORE_FILENAME=server.p12 -e KAFKA_SSL_KEYSTORE_TYPE=PKCS12 \
  -e KAFKA_SSL_KEYSTORE_CREDENTIALS=password -e KAFKA_SSL_KEY_CREDENTIALS=password \
  -e KAFKA_SSL_CLIENT_AUTH=none \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
  apache/kafka:latest >/dev/null
echo "started adm-test-kafka-tls on 127.0.0.1:59292; certificates in $dir"
