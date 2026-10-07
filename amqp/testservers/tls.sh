#!/bin/sh
# A RabbitMQ that takes TLS on 127.0.0.1:55671 and names the user from the
# client certificate (SASL EXTERNAL), for the tests gated on
# ADM_TEST_AMQP_TLS. Usage: tls.sh <folder for the certificates>
#
#   ADM_TEST_AMQP_TLS=127.0.0.1:55671 ADM_TEST_AMQP_CERTS=<folder> adm test network/amqp
#
# The folder gets ca.pem, server.pem/.key and client.pem/.key (CN=guest).
set -e
dir=${1:?usage: tls.sh <folder for the certificates>}
mkdir -p "$dir" && cd "$dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=adm-test-ca" -keyout ca.key -out ca.pem 2>/dev/null
for who in server client; do
  cn=localhost; [ $who = client ] && cn=guest
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$cn" -keyout $who.key -out $who.csr 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > $who.ext
  openssl x509 -req -in $who.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile $who.ext -out $who.pem 2>/dev/null
done
chmod 644 *.key
cat > rabbitmq.conf <<CONF
listeners.tcp.default = 5672
listeners.ssl.default = 5671
ssl_options.cacertfile = /certs/ca.pem
ssl_options.certfile = /certs/server.pem
ssl_options.keyfile = /certs/server.key
ssl_options.verify = verify_peer
ssl_options.fail_if_no_peer_cert = false
auth_mechanisms.1 = PLAIN
auth_mechanisms.2 = AMQPLAIN
auth_mechanisms.3 = EXTERNAL
ssl_cert_login_from = common_name
loopback_users = none
CONF
printf '[rabbitmq_management,rabbitmq_auth_mechanism_ssl].\n' > enabled_plugins
docker rm -f adm-test-rabbit-tls >/dev/null 2>&1 || true
docker run -d --name adm-test-rabbit-tls -p 127.0.0.1:55671:5671 \
  -v "$dir":/certs:ro,Z \
  -v "$dir/rabbitmq.conf":/etc/rabbitmq/rabbitmq.conf:ro,Z \
  -v "$dir/enabled_plugins":/etc/rabbitmq/enabled_plugins:ro,Z \
  rabbitmq:4-management >/dev/null
echo "started adm-test-rabbit-tls on 127.0.0.1:55671; certificates in $dir"
