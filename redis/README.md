# adm.network.redis

A Redis client. It speaks RESP2 and RESP3 itself, in ADM, over `std.net`: there is no C library
to install. It talks to Redis, Valkey and other servers that speak the same protocol.

```bash
adm get admlang:adm.network.redis
```

```adm
use adm.network.redis

let r = try redis.connect("redis://cache.internal:6379/0")
try r.set("greeting", "hello", expire = 1min)
let greeting = try r.get("greeting")          // ?string
let hits = try r.incr("hits")
try r.hset("user:7", {"name": "Ana", "visits": 3})
let user = try r.hgetAll("user:7")            // map<string, string>
try r.close()
```

## Connecting

| Address | Meaning |
|---|---|
| `redis://[user:password@]host[:port][/database]` | TCP; the port is 6379 when left out |
| `rediss://...` | the same under TLS, the certificate checked against the system's authorities and the host name |
| `unix:///run/redis.sock[?db=2]` | a Unix socket |
| `host[:port]` | TCP |

Options go in the query: `db`, `protocol` (`2` or `3`), `client_name`, `timeout` and
`connect_timeout` in seconds, `pool_size`. The same settings are fields of `Client` for a
client built by hand:

```adm
let r = new redis.Client()
r.username = "app"
r.password = secret            // Secret<string>
r.timeout = 5s
r.poolSize = 16
try r.connect("rediss://cache.internal")
```

The client asks for RESP3 (`HELLO 3`) and goes on in RESP2 with a server that does not know it;
`version()` says which it got, and the typed commands return the same values under both.

A `Client` keeps up to `poolSize` connections (8 by default) and lends one to each command, so
any number of tasks share one client. A command that finds a connection the server closed while
it sat idle is sent once more on a new one.

## Cluster

```adm
let r = try redis.connectCluster("redis://app:secret@10.0.0.1:7000", "10.0.0.2:7000")
try r.set("user:7:name", "Ana")            // goes to the node that serves the key's slot
let name = try r.get("user:7:name")
```

One node's address is enough; more are tried in turn when it does not answer. The first may be
any form `connect` takes, and its user, password and options hold for every node. The client
reads the slot map and where each of the server's commands has its keys (`COMMAND`), and then:

- sends each command to the node of its keys' slot, and follows the node's answer when the map
  is old: `MOVED` (the map is read again), `ASK` while a slot is being moved, `TRYAGAIN` and
  `CLUSTERDOWN` after a pause;
- waits for the cluster to promote a replica when a master cannot be reached, as long as nothing
  was sent yet. A command that was already on its way when the connection broke fails, since it
  may have run;
- needs the keys of one command in one slot. Keys with a common `{tag}` are: `{user:7}:name` and
  `{user:7}:mail` hash by `user:7`. Other keys fail with `ErrorKind.Cluster` (`CROSSSLOT`);
- sends the commands of a pipeline to their nodes, one batch per node, and puts the replies back
  in order. A command the client could not place has an error reply in its place;
- runs a transaction on the node of its first key (`multi("{acct}:a")`, or the first command
  queued); all its keys must be in that slot;
- sends `keys`, `scan`, `dbSize`, `flushDb`, `flushAll`, `randomKey`, `scriptLoad`,
  `scriptExists`, `scriptFlush`, `functionLoad` and `configSet` to every master. `run(script)`
  needs no `scriptLoad`: it sends the source to a node that does not have the script;
- subscribes on any node (`subscribe`, `psubscribe`), and on the node of the channel's slot for
  `ssubscribe`, which takes a subscription of its own per slot.

`readFromReplicas = true` on the client sends read-only commands to a replica of the shard when
it has one; what a replica answers may be a little behind its master. A cluster has one
database, 0.

## Sentinel

```adm
let r = new redis.Client()
r.password = "secret"
try r.connectSentinel("mymaster", "10.0.0.1", "10.0.0.2", "10.0.0.3")
```

The addresses name sentinels (port 26379 when left out; a user and a password in one are the
sentinel's own). The client asks them in turn for the master of the name, connects to it and
checks with `ROLE` that it is one, on every connection it opens. When the master cannot be
reached, has become a replica (`READONLY`), or dropped the connection as it was demoted, the
client asks the sentinels again and goes on with the master they promoted, waiting up to
`connectTimeout` for it. It learns of the other sentinels from the one that answered.

Until the sentinels demote an old master it still answers, and the client stays with it: that
takes as long as the group's failover does.

## Commands

Every command family has methods named after the Redis commands: keys (`del`, `exists`,
`expire`, `ttl`, `rename`, `scan`, ...), strings (`get`, `set`, `incr`, `mget`, `mset`,
`append`, bits, HyperLogLog), hashes (`hset`, `hget`, `hgetAll`, `hincr`, field expiry),
lists (`lpush`, `rpop`, `lrange`, `blpop`, `lmove`), sets (`sadd`, `sinter`, `sunionStore`),
sorted sets (`zadd`, `zrange`, `zrangeByScore`, `zpopMin`, `bzpopMin`) and geo, streams
(`xadd`, `xrange`, `xread`, consumer groups), scripts (`eval`, `run`, `fcall`), and the server
(`ping`, `info`, `dbSize`, `configGet`).

- A value written is text, bytes, a number or a boolean (sent as `1` and `0`). A value read
  comes back as `string`; `getBytes` and `Value.bytes()` give the bytes of one that is not text.
- A missing key or member is `none` (`get` returns `?string`), not an error.
- Durations are `duration` values: `expire("k", 30s)`, `set("k", v, expire = 1h)`.
- Commands that wait on the server take the wait: `blpop(["jobs"], 5s)`, `xread(streams, wait
  = 5s)`; `0s` waits without end. The client's `timeout` is added to it.
- Where the Redis name is an ADM keyword or a module: `TYPE` is `typeOf`, `TIME` is
  `serverTime`, `MULTI`/`EXEC` are `multi` and `Transaction.exec`, `GETEX` is `get(key,
  expire)`, `SET ... GET` is `swap`.

`command` sends anything the client has no method for and returns the reply as a `Value`:

```adm
let reply = try r.command("OBJECT", "ENCODING", "greeting")
print(reply.text())
```

`Value` carries the RESP type (`kind`) and reads it as `text()`, `bytes()`, `toInt()`,
`toFloat()`, `toBool()`, `items`, `strings()`, `entries()` (a map, or the flat pair list RESP2
sends in its place) and `get(key)`.

`scan`, `sscan`, `hscan` and `zscan` return a `Scanner`: `next()` gives a page and `none` at
the end, `all()` collects the rest.

## Pipelines and transactions

A `Pipeline` sends any number of commands in one write and reads their replies in order:

```adm
let p = r.pipeline()
for let (i, name) in names {
	try p.add("HSET", "user:{i}", "name", name)
}
let replies = try p.run()         // Value[]; a refused command is an error value in its place
```

A `Transaction` runs its queued commands as one unit (`MULTI`/`EXEC`) on a connection it holds
until `exec` or `discard`. Watched keys make it conditional:

```adm
let tx = try r.multi("stock")                    // WATCH stock
let stock = (try tx.command("GET", "stock")).toInt()
try tx.queue("SET", "stock", stock - 1)
try tx.queue("RPUSH", "orders", order)
let replies = try tx.exec()                      // ErrorKind.Aborted when stock changed meanwhile
```

Redis has no rollback: a command that fails while the unit runs leaves an error value in the
replies and the others still ran. A command the server refuses when it is queued aborts the
whole unit.

## Publish and subscribe

```adm
let news = try r.subscribe("news", "alerts")
try news.psubscribe("user:*")
for {
	let m = try news.receive()                   // receive(5s) gives up after five seconds
	break when m is none
	print("{m.channel}: {m.text()}")
}

try r.publish("news", "hello")
```

A `Subscription` has a connection of its own and one task uses it at a time. It also takes
shard channels (`ssubscribe`, Redis 7). Redis keeps nothing for a subscriber that is away: use
a stream when every message must arrive.

## Scripts

```adm
let take = new redis.Script("return redis.call('DECRBY', KEYS[1], ARGV[1])")
let left = (try r.run(take, ["stock"], 3)).toInt()
```

`run` sends the script's SHA-1 digest and the source only when the server does not have it. A
Lua table in a script written as an ADM string needs its braces escaped: `"return \{1, 2\}"`.

## Errors

Every failure is a `redis.RedisError` with a `kind`: `Connection`, `TimedOut`, `Closed`,
`Protocol`, `Argument`, `Denied` (`NOAUTH`, `WRONGPASS`, `NOPERM`), `WrongType`, `NoScript`,
`Busy`, `Loading`, `ReadOnly`, `OutOfMemory`, `Aborted`, `Cluster`, `Server`. `prefix` holds
the first word of the server's error reply.

```adm
r.get("list") onerror (err error) {
	if err is redis.RedisError {
		print(err.prefix) when err.kind == redis.ErrorKind.WrongType
	}
	recover none
}
```

## Not built yet

- Splitting a command over slots (`del`, `mget`, `mset` with keys of several slots).
- Sentinel: reading from replicas, and listening for `+switch-master` to leave an old master
  before it is demoted.
- Pipelines send their per-node batches one after another, not at the same time.
- Client-side caching (`CLIENT TRACKING`): invalidation pushes are read and dropped.
- Exclusive score bounds in `zrangeByScore`/`zcount`; use `command`.

## Tests

`adm test network/redis` runs the protocol suite and passes the rest without running. With a
server the whole suite runs; it empties database 9 and creates and deletes the ACL user
`adm-test-user`:

```bash
docker run -d -p 127.0.0.1:6379:6379 redis
ADM_TEST_REDIS=127.0.0.1:6379 adm test network/redis
```

The cluster and sentinel tests run against servers of their own, which `testservers/` starts:
six cluster nodes (three masters with a replica each), and a master, two replicas and three
sentinels watching it as `mymaster`. Both use the host's network.

```bash
docker run -d --name redis-cluster --network host -v $PWD/network/redis/testservers/cluster.sh:/c.sh:ro redis sh /c.sh
docker run -d --name redis-sentinel --network host -v $PWD/network/redis/testservers/sentinel.sh:/s.sh:ro redis sh /s.sh
ADM_TEST_REDIS_CLUSTER=127.0.0.1:42100 \
ADM_TEST_REDIS_SENTINEL=mymaster@127.0.0.1:57200,127.0.0.1:57201 adm test network/redis
```

They move a slot between nodes under a client, make a replica take over in the cluster, and
have the sentinels fail the master over (about ten seconds). `ADM_TEST_REDIS_HARD=1` also stops
a cluster master for good; start the cluster again afterwards (`docker restart redis-cluster`).

Not covered by the suite: TLS (`rediss:`) and Unix sockets, which need a server set up for them.
