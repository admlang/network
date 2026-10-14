# adm.network.etcd

An etcd v3 client. It speaks the gRPC API over `std.net.grpc`, in ADM: key-value with
transactions, watches, leases, locks and elections, against etcd 3.4 and later.

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

let lease = try cluster.grant(10s)                           // kept alive until closed
try cluster.put("/workers/{id}", "alive", lease = lease)
let lock = try cluster.lock("/locks/rebuild", lease)
try lock.unlock()
```

## Tests

`adm test network/etcd` runs the message suites and passes the rest without running. With a
server the whole suite runs, under the prefix `/adm-test/` it creates and deletes:

```bash
docker run -d -p 127.0.0.1:2379:2379 quay.io/coreos/etcd:v3.6.0 etcd --advertise-client-urls http://0.0.0.0:2379 --listen-client-urls http://0.0.0.0:2379
ADM_TEST_ETCD=127.0.0.1:2379 adm test network/etcd
```
