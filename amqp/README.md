# adm.network.amqp

An AMQP 0-9-1 client. It speaks the protocol itself, in ADM, over `std.net`: there is no C
library to install. It talks to RabbitMQ and to brokers that speak the same protocol (LavinMQ,
Apache Qpid).

```bash
adm get admlang:adm.network.amqp
```

```adm
use adm.network.amqp

let mq = try amqp.connect("amqp://app:secret@broker.internal/orders")
let ch = try mq.channel()
try ch.declareQueue("jobs", durable = true)
try ch.publish("", "jobs", "resize 7.png")

let jobs = try ch.consume("jobs")
let d = try jobs.next(5s)                     // ?Delivery
if !(d is none) {
	print(d.text())
	try d.ack()
}
try mq.close()
```

## Connecting

| Address | Meaning |
|---|---|
| `amqp://[user[:password]@]host[:port][/vhost]` | TCP; the port is 5672 when left out |
| `amqps://...` | the same under TLS (port 5671), the certificate checked against the system's authorities and the host name |
| `host[:port]` | TCP |

Without a user the connection logs in as `guest`/`guest`; without a path it uses the virtual
host `/`. Options go in the query (`?heartbeat=30&name=billing`) or in the fields of a
`Connection` made with `new`:

| Field | Query | Default | Meaning |
|---|---|---|---|
| `username`, `password`, `vhost` | in the URL | `guest`, `guest`, `/` | who connects and to which virtual host |
| `auth` | `auth_mechanism` | `Auth.Plain` | `Plain`, `AMQPlain`, or `External` (the TLS client certificate names the user) |
| `name` | `name` | "" | the name the broker's management pages show for the connection |
| `tls` | | none | a `tls.Config`: own authorities, a client certificate |
| `heartbeat` | `heartbeat` (seconds) | 60s | how often the two sides send a sign of life; the connection is given up after two silent intervals |
| `frameMax` | `frame_max` | 131072 | the largest frame; a body travels in as many as it needs |
| `channelMax` | `channel_max` | 2047 | how many channels the connection opens at most |
| `connectTimeout` | `connection_timeout` (seconds) | 30s | how long opening the connection may take |
| `timeout` | `timeout` (seconds) | 30s | how long an answer from the broker may take |
| `reconnect`, `reconnectWait`, `onReconnect` | | false, 1s | see Coming back after a break |

```adm
let mq = new amqp.Connection()
mq.auth = amqp.Auth.External
mq.tls = tls.Config{certificates: [try tls.loadKeyPair("client.pem", "client.key")]}
try mq.connect("amqps://broker.internal")
```

`mq.server()` is what the broker says about itself, `mq.blocked()` its reason for not taking
published messages right now (it is short of memory or disk) or none,
`mq.updateSecret(token)` renews credentials that expire.

## Coming back after a break

```adm
let mq = new amqp.Connection()
mq.reconnect = true
mq.onReconnect = def () { print("back") }
try mq.connect("amqp://app:secret@broker.internal")
```

With `reconnect` a connection that breaks dials again (after `reconnectWait`, 1s, then twice as
long each time up to 30 seconds), reopens its channels and does again what each one did:
exchanges, queues, bindings, `qos`, `confirms` or `selectTx`, and consumers, which go on
delivering to the same `Consumer`. What was deleted, unbound or cancelled stays so.

- While the connection is away calls fail with `ErrorKind.Connection`; a `Consumer.next` keeps
  waiting.
- A delivery of the old connection cannot be answered (`ack` fails); the broker hands the
  message out again, marked `redelivered`.
- A message published without confirms just before the break may be lost; with confirms its
  `publish` fails.
- A queue the broker named gets a new name. The channel's calls take the first name on;
  `ch.queueName(first)` is the current one, for a message published to the default exchange.
- A broker that refuses the login, and a channel whose setup the broker refuses on the way
  back (a queue another connection now holds exclusively), end for good.

Without `reconnect` a connection that breaks stays broken: its consumers end with the error.

## Channels

Work happens on channels: `mq.channel()` opens one, and a connection carries up to
`channelMax` of them. A channel runs one call at a time, so give each task that waits for
answers its own.

The broker closes a channel on an error (a queue that does not exist, a second
acknowledgement). The call that caused it fails with the broker's reason, every later call on
that channel with the same, and the connection stays good for a new channel.

## Exchanges and queues

```adm
try ch.declareExchange("events", amqp.ExchangeKind.Topic, durable = true)
let q = try ch.declareQueue("billing", durable = true, arguments = {"x-queue-type": "quorum"})
try ch.bindQueue("billing", "events", "orders.*.paid")
print("{q.messages} waiting, {q.consumers} consumers")

let mine = try ch.declareQueue(exclusive = true)     // a name from the broker, gone with the connection
```

| Method | Does |
|---|---|
| `declareExchange(name, kind, durable, autoDelete, inner, passive, arguments)` | makes an exchange or checks the one that exists; `kind` is an `ExchangeKind` or the name of a plugin's kind |
| `deleteExchange(name, ifUnused)` | removes it |
| `bindExchange(destination, source, key, arguments)`, `unbindExchange(...)` | routes from one exchange to another |
| `declareQueue(name, durable, exclusive, autoDelete, passive, arguments)` | makes a queue or checks the one that exists; returns `QueueInfo{name, messages, consumers}` |
| `bindQueue(queue, exchange, key, arguments)`, `unbindQueue(...)` | routes from an exchange to a queue |
| `purgeQueue(queue)`, `deleteQueue(queue, ifUnused, ifEmpty)` | empty or remove a queue; both return how many messages went |

`passive = true` makes nothing and fails with `ErrorKind.NotFound` unless the thing exists.
RabbitMQ 4 refuses a queue that is neither `durable` nor `exclusive`.

Tables (`arguments`, message headers) are `map<string, any>` holding booleans, integers,
floats, text, bytes, `time.Time`, `amqp.Decimal`, none, arrays and tables.

## Publishing

```adm
try ch.publish("events", "orders.7.paid", "paid")                 // text
try ch.publish("", "jobs", bytes)                                 // the default exchange: straight to a queue
try ch.publish("events", "orders.7.paid", amqp.Message{
	body: payload, contentType: "application/json", persistent: true,
	headers: {"attempt": 1}, expires: 5min, correlationId: id, replyTo: "answers"})
```

`Message` carries the body and the protocol's properties: `contentType`, `contentEncoding`,
`headers`, `persistent`, `priority`, `correlationId`, `replyTo`, `expires`, `messageId`,
`timestamp`, `kind` (the protocol's `type`), `userId`, `appId`.

Without more, `publish` returns when the message is written and the broker says nothing about
it. Publisher confirms make the broker answer for each one:

```adm
try ch.confirms()
try ch.publish("", "jobs", "resize 8.png", mandatory = true)      // returns once the broker took it
```

- `publish` then fails with `ErrorKind.Refused` when the broker refuses the message (a full
  queue with `x-overflow: reject-publish`) and with `ErrorKind.Unroutable` when a `mandatory`
  message matched no queue.
- For throughput set `ch.confirmWait = false`: `publish` returns at once and
  `ch.waitConfirms(timeout)` waits for all answers so far, failing with `ErrorKind.Refused` if
  any message was refused.
- `ch.onReturn = def (back amqp.Returned) { ... }` is called with every message the broker
  sends back, with or without confirms.

Transactions are the protocol's other way: `ch.selectTx()`, then publishes and
acknowledgements take effect at `ch.commitTx()` or are dropped by `ch.rollbackTx()`. A channel
uses confirms or transactions, not both.

## Consuming

```adm
try ch.qos(10)                                    // at most 10 unanswered deliveries per consumer
let jobs = try ch.consume("jobs")
for {
	let d = try jobs.next()                       // waits; next(5s) returns none after 5 s
	continue when d is none
	work(d.message) onerror (err error) {
		try d.nack(requeue = true)
		continue
	}
	try d.ack()
}
```

With a handler, each delivery is passed to it on a task of the consumer's own, one at a time:

```adm
let jobs = try ch.consume("jobs", def (d amqp.Delivery) {
	work(d.message) onerror recover none
	d.ack() onerror recover none
})
```

- A `Delivery` has the `message`, `exchange`, `routingKey`, `redelivered`, its `tag` and
  `text()`; it is answered with `ack(multiple)`, `nack(requeue, multiple)` or
  `reject(requeue)`. With `autoAck = true` the broker counts a message as done when it sends
  it and no answer is due.
- `jobs.cancel()` ends the subscription; `next` then returns what already arrived and fails
  with `ErrorKind.Closed` after it. It fails the same way when the broker cancels the consumer
  (its queue was deleted) or the channel closes.
- `ch.get(queue, autoAck)` takes one message without subscribing, or none.
- `ch.redeliver(requeue)` asks for every unanswered delivery of the channel again.

## Errors

Everything fails with an `AmqpError`; `kind` says what happened and `replyCode` holds the
broker's number when it has one.

| `ErrorKind` | When |
|---|---|
| `Connection` | the broker cannot be reached, TLS fails, the connection breaks or goes silent |
| `TimedOut` | no answer within `timeout` |
| `Closed` | used after `close`, or a consumer that ended |
| `Denied` | wrong user or password, no access to the virtual host or the resource (403, 530) |
| `NotFound` | no such queue, exchange or virtual host (404) |
| `Locked` | another connection holds the queue exclusively (405) |
| `Precondition` | declared again with other properties, unknown delivery tag, not transactional (406) |
| `Unroutable` | a mandatory message matched no queue (312), an immediate one no consumer (313) |
| `Refused` | the broker refused a published message (`basic.nack`) |
| `Protocol` | the broker does not speak AMQP 0-9-1, or broke its rules |
| `Argument` | a name over 255 bytes, a table value of another type, a bad address or option |
| `Server` | any other close from the broker |

## Not built yet

- RabbitMQ streams over their own protocol (a stream queue is usable over AMQP with
  `x-queue-type: stream` and `x-stream-offset`).
- AMQP 1.0.

## Tests

`codec_test.adm` runs without a broker. The others pass without running unless they are told
where one is; they use queues and exchanges named `adm-test-*` in the virtual host `/`:

```bash
docker run -d --name rabbit -p 127.0.0.1:5672:5672 rabbitmq:4
ADM_TEST_AMQP=guest:guest@127.0.0.1:5672 adm test network/amqp
```

`testservers/tls.sh <folder>` starts a broker that takes TLS and certificate logins and writes
its certificates to the folder; `ADM_TEST_AMQP_TLS=127.0.0.1:55671 ADM_TEST_AMQP_CERTS=<folder>`
runs the test for them. `TestBlocked` runs with `ADM_TEST_AMQP_BLOCKED=1` while the broker is
pushed over its memory limit (the test's comment has the commands). `TestReconnect` runs with
`ADM_TEST_AMQP_ADMIN=http://guest:guest@127.0.0.1:15672`, the management API it closes its own
connection through (the `rabbitmq:4-management` image, port 15672).
