#!/bin/sh
# The Java half of TestJavaSide: Kafka's own console producer writes keyed
# records with every compression into adm-test-interop (3 partitions).
#
#   java-side.sh produce <container> <host:port>    before the test
#   java-side.sh list <container> <host:port>       after it: what Java reads
#
#   ADM_TEST_KAFKA=<host:port> ADM_TEST_KAFKA_JAVA=1 adm test network/kafka
set -e
K="docker exec -i ${2:?container} /opt/kafka/bin"
B="--bootstrap-server ${3:?host:port}"
case "$1" in
produce)
  $K/kafka-topics.sh $B --delete --topic adm-test-interop >/dev/null 2>&1 || true
  sleep 1
  $K/kafka-topics.sh $B --create --topic adm-test-interop --partitions 3 >/dev/null
  for c in none gzip snappy lz4 zstd; do
    printf 'key-%s-1:java %s 1\nkey-%s-2:java %s 2\nkey-%s-3:java %s 3\n' $c $c $c $c $c $c |
      $K/kafka-console-producer.sh $B --topic adm-test-interop --compression-codec $c \
        --reader-property parse.key=true --reader-property key.separator=: >/dev/null 2>&1
  done
  ;;
list)
  $K/kafka-console-consumer.sh $B --topic adm-test-interop --from-beginning --timeout-ms 6000 \
    --formatter-property print.key=true --formatter-property print.partition=true 2>/dev/null | sort
  ;;
esac
