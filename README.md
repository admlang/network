# ADM network clients

Official [ADM](https://github.com/admlang/adm) libraries that connect an ADM program to
infrastructure services. Each is written in ADM over `std.net`, published as
`adm.network.<name>` and signed by the `admlang` publisher. They live outside the standard
library so that a fix or a new protocol version ships without a std release.

| Library | Service | How it connects |
|---|---|---|
| [`adm.network.redis`](redis/) | Redis, Valkey and servers that speak RESP | RESP2 and RESP3 over TCP, TLS or a Unix socket; Redis Cluster and Sentinel |
| [`adm.network.s3`](s3/) | Amazon S3 and servers that speak its API (MinIO, Ceph, Garage, R2, B2) | Signature Version 4 over HTTP or HTTPS, path or virtual-host addressing |

## Tests

The suites that need a server pass without running unless they are told where one is:

```bash
ADM_TEST_REDIS=127.0.0.1:6379 adm test network/redis
ADM_TEST_S3=http://key:secret@127.0.0.1:9000 adm test network/s3
```

Each library's README says what the server must hold.
