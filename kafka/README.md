# adm.network.kafka

An Apache Kafka client. It speaks the Kafka protocol itself, in ADM, over `std.net`: there is no
C library to install. It talks to Kafka brokers from version 2.4 on and to the services that
speak the same protocol (Redpanda, Amazon MSK, Confluent Cloud, Azure Event Hubs).

```bash
adm get admlang:adm.network.kafka
```

```adm
use adm.network.kafka

let k = try kafka.connect("broker1:9092", "broker2:9092")
try k.createTopic("orders", partitions = 6)

let out = try k.producer()
let sent = try out.send("orders", "paid", key = "order-7")     // Sent{topic, partition, offset}

let orders = try k.consumer("billing", "orders")
for let record in try orders.poll(1s) {
	print("{record.partition}/{record.offset}: {kafka.text(record)}")
}
try orders.close()
try out.close()
try k.close()
```

## Connecting

| Address | Meaning |
|---|---|
| `host[:port]` | a broker; the port is 9092 when left out |
| `kafka://[user:password@]host[:port]` | the same, with a login |
| `kafkas://...` | under TLS, the certificate checked against the system's authorities and the host name |

One address is enough: the client asks the first broker that answers for the others. More
addresses help when that broker is down.

| Field of `Client` | Default | Meaning |
|---|---|---|
| `clientId` | `adm` | the name brokers log and apply quotas to |
| `sasl` | `Sasl.None` | `Plain`, `ScramSha256`, `ScramSha512`, or `OAuthBearer` (the token is the password) |
| `username`, `password` | | who logs in; a user in an address logs in with SCRAM-SHA-256 unless `sasl` says otherwise |
| `secure`, `tls` | false, none | TLS, and a `tls.Config` with own authorities or a client certificate |
| `connectTimeout` | 30s | how long opening a connection may take |
| `timeout` | 30s | how long an answer may take, and for how long a request that fails for a passing reason is tried again |

```adm
let k = new kafka.Client()
k.sasl = kafka.Sasl.Plain
try k.connect("kafkas://app:secret@broker.internal:9093")
```

## Producing

```adm
let out = try k.producer()
out.compression = kafka.Compression.Zstd
try out.send("orders", "paid", key = "order-7")
try out.send("orders", bytes, partition = 2, headers = [kafka.Header{name: "trace", value: id}])
try out.tombstone("orders", "order-7")            // a record without a value

for let line in lines {
	try out.sendLater("log", line)                // does not wait
}
try out.flush()                                   // fails with the first record that was not sent
```

- Records with the same key go to the same partition, the one every Kafka client picks
  (murmur2). Records without a key are spread over the partitions a batch at a time.
- Records of one partition leave in batches, in the order they were given. Many tasks may
  send through one producer; what they send while a batch is on its way shares the next one.
- A batch that fails for a reason that passes (a partition changing its leader, a broker
  restarting) is sent again for up to `deliveryTimeout`.

| Field of `Producer` | Default | Meaning |
|---|---|---|
| `acks` | `Acks.All` | who must have a record before `send` returns: `All` in-sync replicas, the `Leader`, or `None` |
| `compression` | `None` | `Gzip`, `Snappy`, `Lz4`, `Zstd` |
| `idempotent` | true | brokers drop what a retry would write twice; needs `Acks.All` |
| `linger` | 0s | how long a batch waits for more records |
| `batchBytes` | 16384 | a batch closes at this size |
| `timeout` | 30s | how long a broker may wait for its replicas |
| `deliveryTimeout` | 2min | how long a batch is tried before `send` fails |
| `transactionalId`, `transactionTimeout` | "", 1min | see Transactions |

## Consuming

A consumer in a group shares the topics' partitions with the group's other members, and the
group remembers how far each partition was read:

```adm
let orders = try k.consumer("billing", "orders", "refunds")
for {
	for let record in try orders.poll(1s) {
		handle(record)
	}
}
```

- A `Record` has `topic`, `partition`, `offset`, `key`, `value`, `deleted` (no value),
  `timestamp` and `headers`; `kafka.text(record)`, `kafka.keyText(record)` and
  `kafka.header(record, name)` read them as text.
- With `autoCommit` (the default) the place after the records `poll` returned is committed on
  a later `poll` and on `close`: a record is seen again after a crash unless it was handled
  before the next `poll`. Turn it off and call `commit()` or `commit(record)` to decide
  yourself.
- When members join or leave, the group deals its partitions anew. The next `poll` gives up
  the old ones (`onRevoked`), takes the new (`onAssigned`) and goes on from the committed
  offsets. A `commit` that the change overtook fails with `ErrorKind.Rebalanced`.
- One task polls a consumer, at least once per `rebalanceTimeout`.

A reader has no group: it reads the partitions it names (or all of a topic) alone and commits
nothing.

```adm
let tail = try k.reader("orders")                 // every partition
tail.startFrom = kafka.Start.Latest
let one = try k.reader("orders", 2)               // partition 2
try one.seek("orders", 2, 1500)
```

`seek(topic, partition, offset)`, `seek(topic, partition, Start.Earliest)`, `pause`, `resume`,
`assign`, `assignment()` and `positions()` work on both.

| Field of `Consumer` | Default | Meaning |
|---|---|---|
| `startFrom` | `Start.Earliest` | where to begin in a partition the group has no offset for |
| `autoCommit`, `commitEvery` | true, 5s | commit on `poll` every so often, and on `close` |
| `readCommitted` | false | leave out records of open and rolled-back transactions |
| `sessionTimeout` | 45s | without a heartbeat for this long the group gives the partitions away |
| `rebalanceTimeout` | 5min | how long members have to rejoin, and the longest pause between polls |
| `heartbeatEvery` | 3s | |
| `strategy` | `Strategy.Range` | how the group deals partitions: `Range`, `RoundRobin`, `Sticky` (each partition stays with its member where an even deal allows) or `CooperativeSticky` (the same, and members keep reading through a rebalance: only the partitions that move are given up, and `onRevoked`/`onAssigned` name just those). Every member of a group names the same one |
| `protocol` | `GroupProtocol.Classic` | `Next` speaks the group protocol of Kafka 4: the coordinator deals the partitions, and a change moves only what must move. A group speaks one protocol |
| `instanceId` | "" | a name that survives restarts: the group keeps the member's partitions for it |
| `maxWait`, `minBytes` | 500ms, 1 | how long a broker may hold a fetch that has less than `minBytes` |
| `maxBytes`, `partitionBytes` | 50 MiB, 1 MiB | the most one fetch returns, in all and per partition |

## Transactions

A producer with a `transactionalId` writes records that become visible together, to consumers
with `readCommitted`, or never:

```adm
let out = try k.producer()
out.transactionalId = "billing-1"
let orders = try k.consumer("billing", "orders")
orders.autoCommit = false

for {
	let batch = try orders.poll(1s)
	continue when batch.len() == 0
	try out.beginTx()
	for let record in batch {
		try out.send("invoices", invoiceFor(record))
	}
	try out.sendOffsets(orders)                   // the group's place moves with the transaction
	try out.commitTx()                            // or abortTx()
}
```

A new producer with the same id takes over from an older one, whose calls then fail with
`ErrorKind.Fenced`.

## Topics, offsets and groups

| Method of `Client` | Does |
|---|---|
| `brokers()`, `controller()`, `clusterId()` | the cluster |
| `topics()`, `topic(name)` | `TopicInfo{name, hidden, partitions}` with leader, replicas and in-sync replicas |
| `createTopic(name, partitions, replication, config)` | makes a topic; -1 takes the broker's default |
| `deleteTopic(name)`, `addPartitions(name, total)` | |
| `topicConfig(name)`, `setTopicConfig(name, values, remove)`, `brokerConfig(id)` | settings as text |
| `earliest(topic, partition)`, `latest(...)`, `offsetAt(topic, partition, time)` | offsets |
| `deleteRecords(topic, partition, before)` | drops records before an offset |
| `groups()`, `group(id)`, `committed(group, topic)`, `deleteGroup(id)` | consumer groups |

## Errors

Everything fails with a `KafkaError`; `kind` says what happened and `errorCode` holds the
broker's number when it has one. Errors that pass by themselves are retried inside for up to
the timeout and show as `TimedOut` when they do not pass.

| `ErrorKind` | When |
|---|---|
| `Connection` | no broker can be reached, TLS fails, a connection breaks |
| `TimedOut` | no answer in time, or a partition or coordinator stayed unavailable |
| `Closed` | used after `close` |
| `Denied` | wrong user or password, or no permission |
| `NotFound` | no such topic, partition or group |
| `Exists` | the topic already exists |
| `Argument` | a name, count, setting or option that is refused |
| `TooLarge` | a record over the broker's limit, a batch over `partitionBytes` |
| `OutOfRange` | an offset the partition does not hold |
| `Rebalanced` | the group changed and a commit did not happen |
| `Fenced` | a newer producer or group member with the same id took over |
| `State` | a call that does not fit: no transaction open, a group that still has members |
| `Corrupt` | records that fail their checksum |
| `Unsupported` | a broker too old for a request, or records in the format before Kafka 0.11 |
| `Protocol` | a broker broke the protocol's rules |
| `Server` | any other error from a broker |

## Not built yet

- Describing a group of the Kafka 4 protocol (`group(id)` asks the classic way), and regular
  expression subscriptions.
- Access control lists, quotas, delegation tokens, partition reassignment and the other
  cluster administration requests.
- Fetching from follower replicas by rack, and fetch sessions.
- GSSAPI (Kerberos) logins.

## Tests

The tests pass without running unless they are told where a broker is; they make and delete
topics and groups named `adm-test-*`:

```bash
docker run -d --name kafka --network host \
  -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=PLAINTEXT://127.0.0.1:9092,CONTROLLER://127.0.0.1:9093 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://127.0.0.1:9092 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@127.0.0.1:9093 \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
  apache/kafka:latest
ADM_TEST_KAFKA=127.0.0.1:9092 adm test network/kafka
```

| Variable | Test |
|---|---|
| `ADM_TEST_KAFKA_TLS=host:port` with `ADM_TEST_KAFKA_CERTS=<folder>` | TLS, against the broker `testservers/tls.sh <folder>` starts |
| `ADM_TEST_KAFKA_SASL=host:port` | logins, against the broker `testservers/sasl.sh` starts |
| `ADM_TEST_KAFKA_JAVA=1` | records written by Kafka's own producer (`testservers/java-side.sh produce <container> <host:port>` first; `list` afterwards shows what Kafka's consumer reads back) |
| `ADM_TEST_KAFKA_JAVA_GROUP=<group>` | a group shared with `kafka-console-consumer.sh --group <group> --topic adm-test-interop`; with `ADM_TEST_KAFKA_JAVA_STRATEGY=cooperative-sticky` (or `sticky`) when that consumer runs with `--consumer-property partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor` (`StickyAssignor`), and `next` when it runs with `--consumer-property group.protocol=consumer` |
| `ADM_TEST_KAFKA_HARD=1` | the broker is restarted (`docker restart`) a few seconds into `TestRestart` |
