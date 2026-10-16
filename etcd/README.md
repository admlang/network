# adm.network.etcd

An etcd v3 client. It speaks the gRPC API over `std.net.grpc`, in ADM: key-value with
transactions, watches, leases, locks and elections, members and maintenance, users and roles,
against etcd 3.4 and later.

```bash
adm get admlang:adm.network.etcd
```

```adm
use adm.network.etcd

let cluster = try etcd.connect("https://etcd1.internal:2379", "https://etcd2.internal:2379")
try cluster.put("/config/shop/theme", "dark")
let theme = try cluster.get("/config/shop/theme")            // ?string
for let kv in try cluster.getPrefix("/config/shop/") {
	print("{kv.key} = {kv.value}")
}

let watch = try cluster.watch("/config/shop/", prefix = true)
for let event in watch {
	print("{event.kind} {event.key}")
}

let lease = try cluster.grant(10s)                           // kept alive until revoked
try cluster.put("/workers/{id}", "alive", lease = lease)
let lock = try cluster.lock("/locks/rebuild", lease)
try lock.unlock()
```

## Connecting

`etcd.connect` takes the members' URLs (`http://`, `https://`, or a bare `host:port`) or a
`Config`. Calls go to the members in turn; one that cannot be reached is passed over for
`retryDown` and the call goes to the next. Reads go to another member after any failure;
writes only when they never reached a server, so a write is never applied twice.

```adm
let cluster = try etcd.connect(etcd.Config{
	endpoints: ["https://10.0.0.1:2379", "https://10.0.0.2:2379"],
	username: "app", password: secret,                      // or https://app:secret@host:2379
	tlsConfig: tls.Config{rootCAs: pool, certificates: [try tls.loadKeyPair("client.pem", "client.key")]},
	timeout: 5s,
})
```

A user signs in when the client is made, and again whenever the cluster refuses the token.

## Keys

```adm
let kv = try cluster.entry("/config/theme")                  // ?KeyValue: value, revisions, lease
let page = try cluster.range("/logs/", etcd.GetOptions{prefix: true, limit: 100, order: etcd.SortOrder.Descending})
let n = try cluster.count("/logs/", etcd.GetOptions{prefix: true})
let old = try cluster.get("/config/theme", etcd.GetOptions{revision: 41})
let put = try cluster.put("/config/theme", "light", previous = true)   // put.previous: the value before
try cluster.deletePrefix("/sessions/")
try cluster.compact(put.revision)
```

Transactions compare and then write, all at one revision:

```adm
let r = try cluster.txn()
	.compare(etcd.versionIs("/leader", 0))                    // the key does not exist
	.then(etcd.putOp("/leader", me, lease = lease))
	.otherwise(etcd.getOp("/leader"))
	.commit()
if !r.succeeded {
	let holder = r.results[0].range
}
```

`valueIs`, `versionIs`, `createdAt`, `modifiedAt` and `leaseIs` make the compares (`op` picks
`Equal`, `NotEqual`, `Greater` or `Less`; `end` compares every key of a range); `getOp`,
`putOp`, `deleteOp` and `txnOp` (a nested transaction) make the operations.

## Watches

`watch` takes a key, a prefix (`prefix = true`) or a range (`end`), from now on or from an
older `revision`, with the values before each change (`previous = true`), without puts or
deletes (`skipPuts`, `skipDeletes`). When the connection breaks the watch goes on from the next
revision on another member, so no change is lost or repeated. `batch()` returns whole answers
with their revision, progress notifications included (`progress = true`, or
`requestProgress()`). A watch from a compacted revision fails with `ErrorKind.Compacted`.

## Leases, locks and elections

`grant(ttl)` keeps the lease alive in the background until `revoke()` (or
`stopKeepAlive()`); one stream renews every lease of a client. `lease(id)` takes one granted
elsewhere, `timeToLive(keys = true)` lists its keys, `alive()` says whether it is still held.

```adm
let lock = try cluster.lock("/locks/report", timeout = 30s)     // a lease of its own, revoked by unlock
try lock.unlock()

let election = cluster.election("/elections/scheduler")
let lead = try election.campaign(hostName)                   // waits until this one leads
try lead.proclaim("{hostName} v2")
for let leader in try election.observe() {
	print("leader: {leader.value}")
}
try lead.resign()
```

## Configuration

`etcd.Source` feeds the Config service of `std.services.config` with the keys under a prefix:
the names between the slashes after it, joined by dots, are the configuration key, so
`/config/shop/db/host` under `/config/shop/` is `db.host`. The keys are read at each load and
watched while the service is started, from the revision the load saw, so a change made
meanwhile is not missed; a run of changes makes one reload once it rests.

```adm
use std.services.config::(Config, ConfigConfig, SourceConfig, FileSource)

try Config.config(ConfigConfig{sources: [
	SourceConfig{source: new FileSource("app.toml")},
	SourceConfig{source: new etcd.Source(cluster, "/config/shop/")},        // wins over the file
]})
try await Config.start()
let theme = try Config.get<string>("theme")
```

With `etcd.ValueFormat.Json` every value is a JSON document: an object's members are the keys
below the key (an object at the prefix itself gives top-level keys), any other value is the
key's own. `name` tells the source apart from another on the same prefix (`etcd <prefix>` by
default).

## Cluster and administration

`members`, `addMember` (as a learner too), `removeMember`, `updateMember`, `promoteMember`;
`status`, `alarms`, `disarm`, `defragment`, `hash`, `hashKV`, `snapshot(writer)`,
`moveLeader`, `downgrade`. The calls about one member take its endpoint. `enableAuth`,
`disableAuth`, `authStatus`, and users and roles: `addUser`, `removeUser`, `changePassword`,
`users`, `userRoles`, `grantRole`, `revokeRole`, `addRole`, `removeRole`, `roles`,
`rolePermissions`, `grantPermission`, `revokePermission`.

## Errors

Every failure is an `etcd.EtcdError` with a `kind`: `Connection`, `TimedOut`, `Denied`,
`NotFound`, `Compacted`, `LeaseExpired`, `TooLarge`, `Argument` or `Server`, and the gRPC
`status` the call ended with.

```adm
cluster.put("/k", "v", lease = lease) onerror (err error) {
	if err is etcd.EtcdError && err.kind == etcd.ErrorKind.LeaseExpired {
		...
	}
}
```

## Tests

`adm test network/etcd` passes the suites without running them unless it is told where a
server is. They use keys under `/adm-test/` and delete them:

```bash
docker run -d -p 127.0.0.1:2379:2379 quay.io/coreos/etcd:v3.6.0 etcd --advertise-client-urls http://0.0.0.0:2379 --listen-client-urls http://0.0.0.0:2379
ADM_TEST_ETCD=127.0.0.1:2379 adm test network/etcd
```

Authentication, TLS with client certificates and a three-member cluster have servers of their
own; each script in `testservers/` starts one in docker and prints the variable to set:

```bash
network/etcd/testservers/auth.sh            # ADM_TEST_ETCD_AUTH=root:secret@127.0.0.1:2389
network/etcd/testservers/tls.sh <folder>    # ADM_TEST_ETCD_TLS=127.0.0.1:2399 ADM_TEST_ETCD_CERTS=<folder>
network/etcd/testservers/cluster.sh         # ADM_TEST_ETCD_CLUSTER=127.0.0.1:2481,127.0.0.1:2482,127.0.0.1:2483
```
