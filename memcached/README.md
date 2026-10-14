# adm.network.memcached

A Memcached client. It speaks the text and meta protocols itself, in ADM, over `std.net`: there
is no C library to install. It talks to memcached 1.6 and later and to the services that speak
its protocol (ElastiCache, Memorystore).

```bash
adm get admlang:adm.network.memcached
```

```adm
use adm.network.memcached

let cache = try memcached.connect("cache1.internal:11211", "cache2.internal:11211")
try cache.set("session:7", data, expire = 30min)
let session = try cache.get("session:7")           // ?bytes
let hits = try cache.increment("hits", 1, initial = 0)
let many = try cache.getMany(["a", "b", "c"])      // map<string, bytes>
try cache.close()
```

## Tests

`adm test network/memcached` runs the protocol suite and passes the rest without running.
With a server the whole suite runs; it flushes that server:

```bash
docker run -d -p 127.0.0.1:11211:11211 memcached
ADM_TEST_MEMCACHED=127.0.0.1:11211 adm test network/memcached
```
