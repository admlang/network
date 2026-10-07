#!/bin/sh
# A Kafka that asks for a login on 127.0.0.1:59192 (PLAIN and SCRAM), for
# the tests gated on ADM_TEST_KAFKA_SASL:
#
#   ADM_TEST_KAFKA_SASL=127.0.0.1:59192 adm test network/kafka
#
# Users: admin/admin-secret (PLAIN), ana/ana-secret (SCRAM-SHA-256 and
# SCRAM-SHA-512); OAUTHBEARER takes unsigned tokens ("alg":"none"). Port 59194 takes no login and is used to make them.
set -e
docker rm -f adm-test-kafka-sasl >/dev/null 2>&1 || true
docker run -d --name adm-test-kafka-sasl --network host \
  -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=SASL_PLAINTEXT://127.0.0.1:59192,CONTROLLER://127.0.0.1:59193,PLAINTEXT://127.0.0.1:59194 \
  -e KAFKA_ADVERTISED_LISTENERS=SASL_PLAINTEXT://127.0.0.1:59192,PLAINTEXT://127.0.0.1:59194 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@127.0.0.1:59193 \
  -e KAFKA_SASL_ENABLED_MECHANISMS=PLAIN,SCRAM-SHA-256,SCRAM-SHA-512,OAUTHBEARER \
  -e KAFKA_OPTS=-Dadm.test=1 \
  -e 'KAFKA_LISTENER_NAME_SASL__PLAINTEXT_PLAIN_SASL_JAAS_CONFIG=org.apache.kafka.common.security.plain.PlainLoginModule required user_admin="admin-secret";' \
  -e 'KAFKA_LISTENER_NAME_SASL__PLAINTEXT_OAUTHBEARER_SASL_JAAS_CONFIG=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required unsecuredLoginStringClaim_sub="broker";' \
  -e 'KAFKA_LISTENER_NAME_SASL__PLAINTEXT_SCRAM___SHA___256_SASL_JAAS_CONFIG=org.apache.kafka.common.security.scram.ScramLoginModule required;' \
  -e 'KAFKA_LISTENER_NAME_SASL__PLAINTEXT_SCRAM___SHA___512_SASL_JAAS_CONFIG=org.apache.kafka.common.security.scram.ScramLoginModule required;' \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
  apache/kafka:latest >/dev/null
sleep 15
for kind in SCRAM-SHA-256 SCRAM-SHA-512; do
  docker exec adm-test-kafka-sasl /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:59194 --alter \
    --add-config "$kind=[password=ana-secret]" --entity-type users --entity-name ana
done
echo "started adm-test-kafka-sasl on 127.0.0.1:59192"
