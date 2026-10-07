# adm.network.s3

An S3 client. It signs requests with AWS Signature Version 4 itself, in ADM, over
`std.net.http`: there is no SDK to install. It talks to Amazon S3 and to the servers that speak
its API (MinIO, Ceph, Garage, Cloudflare R2, Backblaze B2).

```bash
adm get admlang:adm.network.s3
```

```adm
use adm.network.s3

let store = try s3.connect("https://s3.eu-central-1.amazonaws.com", accessKey, secretKey)
let photos = store.bucket("photos")
try photos.put("2026/cat.jpg", pixels, "image/jpeg")
let cat = try photos.get("2026/cat.jpg")          // s3.Object, an io.Reader
let data = try cat.bytes()
for let entry in try photos.list("2026/").all() {
	print("{entry.key} {entry.size}")
}
let link = try photos.presign("2026/cat.jpg", 1h) // a URL anyone can read for an hour
```

## Connecting

`s3.connect(endpoint, accessKey, secretKey, region)` makes a client. It sends nothing: S3 has no
session, every request is signed on its own.

| Endpoint | Meaning |
|---|---|
| `https://s3.eu-central-1.amazonaws.com` | Amazon S3; the region is read from the host |
| `https://s3.amazonaws.com` | Amazon S3 in the client's `region` (`us-east-1` unless set) |
| `http://127.0.0.1:9000` | a server of one's own |
| `https://key:secret@host[:port]` | credentials in the address |
| `host[:port]` | the same as `https://host[:port]` |

Options go in the query: `region`, `addressing` (`path`, `virtual` or `auto`) and `timeout` in
seconds. The same settings are fields of `Client` for a client built by hand:

```adm
let store = new s3.Client()
store.accessKey = key
store.secretKey = secret            // Secret<string>
store.sessionToken = token          // temporary credentials
store.region = "eu-west-1"
store.partSize = 64 * 1024 * 1024
try store.connect("https://s3.amazonaws.com")
```

**Addressing.** `Addressing.Auto` puts the bucket in the host name (`bucket.endpoint/key`) when
the endpoint is a DNS name and the bucket's name fits under its certificate, and in the path
(`endpoint/bucket/key`) otherwise: an IP address, `localhost`, a bucket name that is not a DNS
label, or one with a dot over HTTPS. `Addressing.Path` and `Addressing.VirtualHost` force one.

**Regions.** A request refused because the bucket lives in another region is sent once more,
signed for the region the reply names, and the client remembers it for that bucket.

**Retries.** A request answered with 500, 502, 503 or 504, or whose connection breaks, is sent
again up to `retries` times (3) with a growing pause. A streamed body is never resent.

## Buckets

```adm
let bucket = try store.createBucket("reports")    // in the client's region
let all = try store.buckets()                     // BucketInfo[]
let there = try store.hasBucket("reports")
try store.deleteBucket("reports")                 // ErrorKind.NotEmpty while it holds anything
```

`store.bucket(name)` returns a `Bucket` without asking the server. Its settings:

| Method | What it reads or sets |
|---|---|
| `region()` | where the bucket lives |
| `versioning()`, `versioning(enabled)` | whether every version of an object is kept |
| `policy()`, `policy(json)` | the bucket policy; `none` removes it |
| `tagging()`, `tagging(labels)` | the bucket's tags |
| `configuration(name)`, `configuration(name, document)` | any other configuration document by the name of its subresource (`lifecycle`, `cors`, `encryption`, `notification`, `replication`, `website`, `acl`, `object-lock`, `logging`), as the XML S3 defines; `none` removes it |

## Objects

```adm
try bucket.put("notes/today.md", text, "text/markdown")
try bucket.put("big.iso", file, size)                       // from a reader, not held in memory
try bucket.upload("backup.tar", stream)                     // any length: multipart when large

let object = try bucket.get("notes/today.md")
let info = try bucket.info("notes/today.md")                // ?ObjectInfo, none when missing
let there = try bucket.has("notes/today.md")
try bucket.copy("notes/today.md", "archive/2026-10-07.md")
try bucket.delete("notes/today.md")
let failed = try bucket.delete(["a", "b", "c"])             // a thousand per request
```

- `get` returns an `Object`: `info` describes it, and the content is still on the wire. Take it
  with `bytes()`, `text()`, `copyTo(writer)`, `save(path)` or `read(buf)`, or `close()` it. A
  missing object fails `get` with `ErrorKind.NoObject`; `info` returns `none` instead.
- `ReadOptions` narrows a read: `offset` and `length` for a range (`offset: -100` is the last
  hundred bytes), `version`, `part`, the conditions `ifMatch`, `ifNoneMatch`, `ifModifiedSince`
  and `ifUnmodifiedSince`, and `customerKey`.
- `WriteOptions` carries what is stored with an object: `metadata`, `cacheControl`,
  `contentDisposition`, `contentEncoding`, `contentLanguage`, `expires`, `storageClass`, `acl`,
  `labels` (its tags), `encryption` with `kmsKey`, `customerKey`, and the conditions `ifMatch`
  and `ifNoneMatch` (`ifNoneMatch: "*"` writes only when there is no object yet).
- `copy` runs inside S3. Without options the copy keeps the source's type and metadata; with
  options they replace them. A source over 5 GiB is copied in parts.
- `tagging(key)` and `tagging(key, labels)` read and replace an object's tags.
- In a bucket that keeps versions, `put` returns the new `version`, `delete(key)` adds a delete
  marker and `delete(key, version)` removes one version for good.

**How bodies are signed.** A body in memory is hashed and the hash signed. A reader is sent as
S3's signed chunks (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`), each chunk carrying a signature
chained from the one before, so it is read once and still protected over plain HTTP.

## Listing

```adm
let everything = try bucket.list("photos/").all()           // ObjectInfo[]

let walk = bucket.list("photos/", "/")                      // one "folder" level
for {
	let page = try walk.next()                              // ?Page, a request per page
	break when page is none
	print(page.prefixes)                                    // photos/2025/, photos/2026/
}

let history = try bucket.versions("notes/today.md").all()   // versions and delete markers
```

`list` takes `prefix`, `delimiter`, `startAfter` and `pageSize`. Keys come back exactly as they
were written, also those XML cannot hold.

## Multipart uploads

`bucket.upload(key, reader)` does everything: a stream shorter than the client's `partSize`
(16 MiB) goes in one request, a longer one in parts sent `uploadTasks` (4) at a time, and the
upload is aborted when anything fails. It holds `uploadTasks` parts in memory, and an object has
at most 10000 parts, so raise `partSize` for objects over 160 GiB.

The steps are there for an upload driven by hand:

```adm
let upload = try bucket.multipart("backup.tar", "application/x-tar")
let first = try upload.part(1, head)                        // 5 MiB to 5 GiB, the last may be smaller
let second = try upload.copyPart(2, "old/backup.tar")       // filled from an object in S3
try upload.complete([first, second])                        // or upload.abort()

let later = bucket.resume("backup.tar", upload.id)          // go on in another process
let sent = try later.parts()
let pending = try bucket.uploads()                          // started, neither completed nor aborted
```

## Presigned URLs and forms

```adm
let link = try bucket.presign("reports/2026.pdf", 1h)
let drop = try bucket.presign("inbox/scan.png", 10min, http.Method.PUT, headers = {"Content-Type": "image/png"})
let named = try bucket.presign("reports/2026.pdf", 1h, params = {"response-content-disposition": "attachment"})
```

A presigned URL lets whoever holds it make one request without credentials, for one second to
seven days. Headers given to `presign` are signed in: the request must send exactly them.

`postForm` signs an upload from a browser form:

```adm
let form = try bucket.postForm("uploads/$\{filename\}", 15min, maxSize = 10 * 1024 * 1024)
// <form action="{form.url}" method="post" enctype="multipart/form-data">
//   one hidden input per entry of form.fields, then <input type="file" name="file">
```

## Anything else

`store.request(method, bucket, key, query, headers, body)` signs and sends a request the client
has no method for and returns the `http.Response`:

```adm
let res = try store.request("GET", "photos", query = {"accelerate": ""})
```

## Errors

Every failure is an `s3.S3Error` with a `kind`: `Connection`, `TimedOut`, `Argument`, `Denied`,
`NoBucket`, `NoObject`, `NoUpload`, `Exists`, `NotEmpty`, `Precondition`, `NotModified`, `Range`,
`Throttled`, `Protocol`, `Server`. `serverCode` holds the server's own code (`NoSuchKey`),
`status` the HTTP status and `requestId` the id to quote to the provider.

```adm
bucket.get("missing") onerror (err error) {
	if err is s3.S3Error {
		print(err.serverCode) when err.kind == s3.ErrorKind.NoObject
	}
	recover placeholder
}
```

## Credentials

Give the keys in the address or in `accessKey`, `secretKey` and `sessionToken`, or let the
client find them where AWS tools do:

```adm
let store = new s3.Client()
try store.credentials()                       // or credentials("work") for a profile
try store.connect("https://s3.amazonaws.com")
```

`credentials` looks, in this order, at `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
(`AWS_SESSION_TOKEN`); the role of `AWS_ROLE_ARN` for the token in
`AWS_WEB_IDENTITY_TOKEN_FILE` (a Kubernetes service account); the profile in
`~/.aws/credentials` and `~/.aws/config` (`AWS_PROFILE`, `AWS_SHARED_CREDENTIALS_FILE`,
`AWS_CONFIG_FILE`; a `role_arn` with `source_profile`, a `credential_process` (run through
the shell, so the application's policy must allow starting programs), and a profile signed in
with `aws sso login`, whose token is renewed when it ends, included); the address a container
platform gives (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` or `_FULL_URI`); the instance metadata
service of a cloud machine (`AWS_EC2_METADATA_DISABLED=true` skips it). `AWS_REGION`,
`AWS_DEFAULT_REGION` or the profile's `region` becomes the region unless one was set.

`store.assumeRole(role, session, length, externalId)` trades the client's keys for the temporary
ones of a role, through STS (AWS's, or the endpoint itself for MinIO and the like); call it
after `connect`. Temporary credentials of every source are renewed five minutes before they
end.

`regionSet = "*"` (or a list of regions) signs with Signature Version 4A, which multi-region
access points ask for.

## Checksums

```adm
try bucket.put("a.bin", data, "", s3.WriteOptions{checksum: s3.Checksum.Crc32c})
let object = try bucket.get("a.bin", s3.ReadOptions{checksum: true})
print(object.info.checksums["crc32c"])        // base64
let content = try object.bytes()              // checked against it
```

`Checksum` is `Crc32`, `Crc32c`, `Sha1` or `Sha256`. S3 refuses content that does not match
and keeps the checksum with the object. Content from memory sends it ahead; a stream sends it
after the content, signed; `upload` and `multipart` give every part its own, and the object the
checksum of those (it ends in `-N`).

## Lifecycle and CORS

```adm
try bucket.lifecycle([
	s3.LifecycleRule{id: "old-logs", prefix: "logs/", expireAfterDays: 30},
	s3.LifecycleRule{id: "tier", transitions: [s3.Transition{days: 90, storageClass: "GLACIER"}]},
])
try bucket.cors([s3.CorsRule{origins: ["https://app.example.com"], methods: ["GET", "PUT"], headers: ["*"], maxAge: 1h}])
let rules = try bucket.lifecycle()            // [] when none are set
```

A `LifecycleRule` covers objects by `prefix`, `labels`, `largerThan` and `smallerThan`, and sets
`expireAfterDays`/`expireOn`, `expireDeleteMarkers`, `noncurrentAfterDays` with
`keepNoncurrent`, `abortUploadsAfterDays`, `transitions` and `noncurrentTransitions`. An empty
list removes the rules.

## Not built yet

- S3 Express session authentication, and the dual-stack, FIPS and access-point host names of
  AWS (such an endpoint works when given whole, with `region` set).
- Under Signature Version 4A a stream is sent unsigned (HTTPS only) and carries no checksum.
- The CRC-64/NVME checksum, and checking a checksum while an object is read as a stream
  (`Object.bytes` checks it).
- Typed replication, notification, ACL and Object Lock settings; they travel as documents
  through `configuration`.
- S3 Select, Batch Operations, inventory and the control-plane APIs.
- Parallel ranged download of one object.

## Tests

`adm test network/s3` runs the signature suite (the worked examples of the S3 API reference)
and passes the rest without running. With a server the whole suite runs; it makes and removes
buckets whose names start with `adm-test-`:

```bash
docker run -d -p 127.0.0.1:9000:9000 -e MINIO_ROOT_USER=admtest -e MINIO_ROOT_PASSWORD=admtest-secret-key minio/minio server /data
ADM_TEST_S3=http://admtest:admtest-secret-key@127.0.0.1:9000 adm test network/s3
```

Not covered by the suite: HTTPS endpoints, customer-provided keys (`customerKey`, which S3
takes over HTTPS only), temporary credentials, copying an object over 5 GiB, and Amazon S3
itself; the suite runs against MinIO.

`credentials_test.adm` runs the credential sources against files and a metadata server of its
own, and `assumeRole` against the test server. Bucket CORS is checked as XML only: MinIO keeps
none per bucket. `testservers/v4a-check.py` compares Signature Version 4A with AWS's signer
(`awscrt`): its signature must verify over the string the test signed, under the key the test
derived.
