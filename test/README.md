# Compatibility Test

Proves `nginx-echo:1.25-bookworm` is a drop-in replacement for `nginx:1.25-bookworm`.

```bash
make test
# or directly:
python test/compat_test.py
```

Stdlib only — no `pip install`. Exits `0` if every scenario matches, `1` on any mismatch.
All 23 scenarios run before exiting, so one run reports everything that differs rather than
stopping at the first failure.

## Approach: differential, not expectation-based

Both images are booted as **separate containers** on dynamically-allocated free ports, and
every request is sent to **both**. The upstream image is the oracle — nothing is asserted
against hardcoded expected values.

This matters: a test asserting `GET /` returns exactly 615 bytes would pass while silently
encoding assumptions that rot. Asserting *the two images agree* keeps testing the property we
actually care about — equivalence — and stays valid if upstream details change.

Both containers get the same `test/custom.conf` bind-mounted to
`/etc/nginx/conf.d/zz-custom.conf`, so config-level behavior is compared too, not just
default-image behavior.

## What "working correctly" means

For every scenario, the candidate must agree with the reference on:

| Aspect | Rule |
|---|---|
| **Status code** | Exact match, always. |
| **Header names** | The *ordered* list must match exactly. A header appearing, disappearing, or moving position is a failure. |
| **Header values** | Exact match, except the three volatile headers below. |
| **Body** | Byte-for-byte identical, except where a scenario declares a regex shape (only `/stub_status`). |

### The volatile-header allowlist

Three headers legitimately differ between the two images. These are consequences of *having
rebuilt the image*, not incompatibilities:

| Header | Why it differs | Still checked |
|---|---|---|
| `Date` | Wall-clock time the response was generated — differs between any two requests to anything. | Must be present and parse as a valid HTTP-date. |
| `Last-Modified` | Derived from the static file's mtime, which is each image's build date (upstream `Apr 16 2024`; ours, our build time). | Same — present and well-formed. |
| `ETag` | nginx computes it from mtime + size, so it inherits the `Last-Modified` difference. | Must be present and match nginx's `"hex-hex"` format. |

The allowlist is deliberately **short, explicit, and justified per entry**, and the headers are
never simply skipped — each is still asserted present and well-formed, so a header vanishing or
turning to garbage is still caught.

**`Server:` is deliberately NOT on the allowlist.** `Server: nginx/1.25.5` matching is
meaningful evidence that we shipped the same nginx version, so it's compared strictly.

One body is treated as volatile: `/stub_status` returns live connection counters, so it's
matched against a regex shape rather than exact bytes.

## What the test covers — 23 scenarios

### Default server (`:80`), stock config
| Scenario | Exercises | Observed |
|---|---|---|
| `GET /` | Root / happy path, static file serving | `200` |
| `GET /50x.html` | Second static file | `200` |
| `GET /does-not-exist` | 404 error page generation | `404` |
| `HEAD /` | Alternate method, header-only response | `200` |
| `POST /` (512 KB) | Method rejection on a static location | `405` |
| `POST /` (2 MB) | `client_max_body_size` default (1m) enforcement | `413` |
| `GET /` + `Range: bytes=0-99` | Partial content / byte ranges | `206` |
| `GET /` + stale `If-None-Match` | Conditional request handling | `200` |
| `GET /` + unknown `Host` | Virtual-host fallback to default server | `200` |
| `GET /aaa…` (9000 chars) | URI length limit | `414` |
| `X-Big:` 10 KB header | Header size limit (`large_client_header_buffers`) | `400` |

### Malformed requests (raw sockets)
No HTTP client will emit a malformed request line, so these are sent as raw bytes over a
socket and the response is parsed by hand.

| Scenario | Exercises | Observed |
|---|---|---|
| Garbage request line (`\x16\x03\x01GARBAGE`) | Parser rejection of binary junk (this is a TLS ClientHello prefix — i.e. HTTPS sent to a plaintext port) | `400` |
| `GET / HTTP/9.9` | Unsupported HTTP version handling | `505` |
| `GET` with no request target | Incomplete request line | `400` |
| Bare-LF line endings (no CR) | Lenient line-ending parsing | `200` |

### Custom config (`:8081`, from `test/custom.conf`)
Several directives double as **module-presence assertions**: if the image were built without
the matching `--with-http_*_module` flag, nginx would fail to start with `unknown directive`
and the test would catch it at boot.

| Scenario | Exercises | Observed |
|---|---|---|
| `GET /` on custom server | Custom `server` block on a non-default port is honored | `200` |
| `GET /teapot` | `return` with a custom status code | `418` |
| `GET /custom-header` | `add_header` emits `X-Compat-Test` | `200` |
| `GET /subfilter` | `--with-http_sub_module` — rewrites body content on the fly | `200` |
| `GET /realip` | `--with-http_realip_module` — `set_real_ip_from` / `real_ip_header` accepted | `200` |
| `POST /teapot` (512 KB) | Raised `client_max_body_size 2m` accepts what the default would reject | `418` |
| `POST /teapot` (2 MB) | Still within the raised limit | `418` |
| `GET /stub_status` | `--with-http_stub_status_module` (body = live counters, shape-matched) | `200` |

## Verification that the test actually detects failures

A test that always passes is worthless, so it was validated against a **negative control** —
a deliberately different nginx image:

```bash
CANDIDATE_IMAGE=nginx:alpine python test/compat_test.py
```

Result: **23 of 23 scenarios flagged**, exit code `1`. It caught `Server: nginx/1.25.5` vs
`nginx/1.31.4`, differing `Content-Length` (615 vs 896 — alpine ships a different
`index.html`), and body mismatches including inside the error pages nginx generates.

Against the real candidate: **all 23 matched**, exit code `0`.

## Known gaps / would-do-next

- **HTTPS/TLS is not exercised.** Neither image ships a certificate, so testing the TLS path
  would mean generating one and mounting a `listen 443 ssl` config into both. Worth adding —
  it's the code path the OpenSSL version bump actually touches. The current test proves the
  bumped OpenSSL didn't *break* anything; it doesn't exercise TLS handshakes directly.
- **HTTP/2 and HTTP/3** are compiled in (`--with-http_v2_module`, `--with-http_v3_module`) but
  untested, for the same certificate reason.
- **Concurrency/load behavior** is out of scope — this tests functional equivalence, not
  performance parity.
- The **njs module** is absent from our build by design (upstream ships it as a separate
  package); no scenario depends on it, but a config using `js_*` directives would fail on our
  image and pass on upstream.
