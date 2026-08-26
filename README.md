# nginx-echo — a drop-in replacement for `nginx:1.25-bookworm`

nginx 1.25.5 rebuilt from upstream source on `debian:bookworm-slim`, with two CVEs eliminated by
two different remediation techniques, and an automated test proving it behaves identically to the
image it replaces.

| | |
|---|---|
| **Replaces** | `nginx:1.25-bookworm` @ `sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c` |
| **Ships** | `nginx-echo:1.25-bookworm` — nginx 1.25.5, package `nginx 1.25.5-1echo1` |
| **Fixed by version bump** | CVE-2024-6119 (OpenSSL) |
| **Fixed by backport** | CVE-2026-60005 (nginx source) |
| **Compatibility** | 23/23 HTTP scenarios byte-identical |

---
## Prerequisites
Requires docker. also pull those images:
```bash
docker pull debian:bookworm-slim
docker pull nginx:1.25-bookworm
```
## Build

Everything compiles inside containers — nothing is installed on the host.

```bash
make image     # builds the .deb from upstream source, then the container image
make test      # boots both images side by side and diffs their HTTP behaviour
```

`make image` runs two stages:

1. **`make deb`** — builds `build/Dockerfile` (a clean `debian:bookworm-slim`), then runs
   [`build/build.sh`](build/build.sh) inside it. That script fetches the nginx 1.25.5 tarball from
   nginx.org, verifies its SHA256, applies the patches in [`build/patches/`](build/patches/),
   configures with flags copied verbatim from upstream's own build, compiles, and packages the
   result with `dpkg-deb`. Output: `dist/nginx_1.25.5-1echo1_amd64.deb`.
2. **`Containerfile`** — installs that `.deb` into a fresh `debian:bookworm-slim` and reproduces
   upstream's runtime layout (user, ports, entrypoint, log symlinks).

Reproduce the exact baseline that was scanned:

```bash
docker pull nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
```

### Notes for other environments

- **Ubuntu / Debian:** `make test PYTHON=python3` — Ubuntu ships no bare `python`.
- **Git Bash on Windows:** prefix docker commands with `MSYS_NO_PATHCONV=1`, or the volume mount
  silently writes nowhere and `dist/` comes out empty.

---

## Image size

| Image | Size |
|---|---|
| `nginx:1.25-bookworm` (upstream) | **276 MB** |
| `nginx-echo:1.25-bookworm` | **143 MB** |

48% smaller — but this is a **side effect, not an optimisation goal**. It comes from not shipping
the separate `nginx-module-njs` package and from `rm -rf /var/lib/apt/lists/*` in the
`Containerfile`. 

---

## CVEs fixed

| CVE | Component | Severity | Method | Evidence |
|---|---|---|---|---|
| **CVE-2024-6119** | OpenSSL (`libssl3`) | High (CVSS 7.5) | **version bump** | `libssl3` 3.0.11 → 3.0.20, asserted at build time in [`build.sh`](build/build.sh); absent from [`grype-post-fix.txt`](grype-post-fix.txt) |
| **CVE-2026-60005** | nginx (`ngx_http_variables.c`) | High (CVSS 8.8) | **backport** | [`build/patches/CVE-2026-60005.patch`](build/patches/CVE-2026-60005.patch) + [`vex/`](vex/) |

### CVE-2024-6119 — version bump

A type-confusion DoS in OpenSSL's X.509 `otherName` handling. `nginx` links `libssl.so.3`
dynamically, so the vulnerable code is in a dependency, not in nginx.

Debian had a fix available (Grype's `FIXED IN` column showed `3.0.14-1~deb12u2`), so the correct
remediation was to link against a patched OpenSSL. Building on a current `debian:bookworm-slim`
pulls `3.0.20-1~deb12u2`.

Because "we installed a newer package" is an assumption rather than a guarantee, `build.sh`
**asserts** it and fails the build otherwise:

```sh
INSTALLED_OPENSSL="$(dpkg-query -W -f='${Version}' libssl3)"
if dpkg --compare-versions "$INSTALLED_OPENSSL" lt "$MIN_FIXED_OPENSSL"; then
    echo "FATAL: libssl3 $INSTALLED_OPENSSL is older than the CVE-2024-6119 fix" >&2
    exit 1
fi
```

The `.deb` also declares `Depends: libssl3 (>= 3.0.14-1~deb12u2)`, so the fix is enforced at
install time too, not just at build time.

**Collateral effect:** bumping a shared library sweeps up everything else fixed in that range.
OpenSSL findings dropped from **40 unique CVEs to 8**. Only CVE-2024-6119 was deliberately
targeted; the other ~32 are a side effect of rebuilding on a current base. They are real fixes,
but they are not engineering I should take credit for.

Although debian tooling is not the preffered way as mentioned in the assignment, I wanted to demonstrate 
understanding of this method too.

### CVE-2026-60005 — backport

Uninitialized memory read in nginx itself. `ngx_http_regex_exec()` reallocates `r->captures` but
doesn't reset `r->ncaptures` when the regex fails to match, so a later `$1` reads a stale count
against a freshly-allocated, uninitialized array — memory disclosure, or a worker crash.

**Why a backport and not a bump:** Debian bookworm has **no fixed nginx package** — the
[security tracker](https://security-tracker.debian.org/tracker/CVE-2026-60005) lists bookworm as
vulnerable, with only `sid` fixed. Grype reflects this with an *empty* `FIXED IN` column. There is
nothing to upgrade to. Upstream fixed it in 1.31.3/1.30.4, but jumping there would stop this being
a drop-in replacement for 1.25. So the fix is ported back onto 1.25.5:

```diff
         if (r->captures == NULL || r->realloc_captures) {
             r->realloc_captures = 0;
+            r->ncaptures = 0;
```

One line, from upstream commit `0cca8e05`. It applies to 1.25.5 with a −59 line offset, no fuzz.

I used those git commands to verify it:
```bash
git clone --filter=blob:none https://github.com/nginx/nginx.git
git log --oneline release-1.31.2..release-1.31.3 | grep regex
git show --format= 0cca8e05

```

nginx does not tag commits with CVE IDs, so the mapping was established from two converging
signals — the 1.31.3 changelog wording, and the commit message.

---

## VEX

VEX is used for the backporting patch, since this method does not change the package name and version, so the
scanners still think the CVE exists even if it is fixed. I added a vex file(JSON formatted) for scanning the image properly.

---

## Compatibility test

```bash
make test        # or: python test/compat_test.py
```

A **differential** test: both images boot as separate containers, the same request goes to each,
and the upstream image is the oracle. Nothing is asserted against hardcoded expectations.

```
  ok     root: GET /  [200]
  ok     static: GET /50x.html  [200]
  ok     404: GET /does-not-exist  [404]
  ok     HEAD /  [200]
  ok     method not allowed: POST / (small body)  [405]
  ok     large body: POST / 2MB exceeds client_max_body_size  [413]
  ok     range: GET / bytes=0-99  [206]
  ok     conditional: GET / with stale If-None-Match  [200]
  ok     host header: GET / with unknown Host  [200]
  ok     long URI: GET /aaa...(9000)  [414]
  ok     oversized header: 10KB X-Big  [400]
  ok     malformed: garbage request line  [400]
  ok     malformed: bad HTTP version  [505]
  ok     malformed: missing request target  [400]
  ok     malformed: bare LF line endings  [200]
  ok     custom cfg: GET / on custom server  [200]
  ok     custom cfg: return 418 /teapot  [418]
  ok     custom cfg: add_header /custom-header  [200]
  ok     custom cfg: sub_filter rewrites body  [200]
  ok     custom cfg: realip module directives accepted  [200]
  ok     custom cfg: raised client_max_body_size accepts 512KB  [418]
  ok     custom cfg: 2MB still under raised 2m limit  [418]
  ok     custom cfg: stub_status module  [200]

All 23 scenarios matched. nginx-echo:1.25-bookworm is a drop-in replacement for nginx:1.25-bookworm.
```

**"Working correctly" means:** identical status; identical *ordered* header names; identical header
values except three documented volatile ones (`Date`, `Last-Modified`, `ETag` — which differ
because the image was rebuilt, and are still checked for presence and well-formedness); and
byte-identical bodies.

23 scenarios cover the default server, error paths, four malformed requests sent over raw sockets,
and a custom config exercising `sub_filter`, `stub_status`, `realip` and `client_max_body_size`.


---

## Scan results

| | Baseline | After |
|---|---|---|
| Unique CVEs | 407 | **95** |
| Findings | 628 | **190** |
| Critical | 41 | 8 |
| High | 179 | 27 |

Files: [`baseline-grype.txt`](baseline-grype.txt) / [`baseline-trivy.txt`](baseline-trivy.txt)
(upstream),[`grype-post-fix.txt`](grype-post-fix.txt) / [`trivy-post-fix.txt`](trivy-post-fix.txt)
(this image, VEX applied).

Most of that reduction is **not** targeted CVE work — it comes from rebuilding on a current Debian
base and from carrying fewer packages. Two CVEs were deliberately fixed; the rest is collateral.

---

## Residual risk

**Three nginx CVEs remain unfixed**, all High or Critical:

| CVE | Why not fixed | What I'd do next |
|---|---|---|
| **CVE-2026-42533** (Critical, 9.2) — heap overflow via `map` + regex | Upstream fix is a **six-commit series** across ~12 files including `ngx_http_script.c`, the log modules, and the proxy/grpc/fastcgi family. `ngx_http_proxy_module.c` alone drifted 450 lines between 1.25.5 and the fix. High risk of subtle breakage in exactly the paths the compatibility test exercises. | Port the series with per-commit verification, or move to the 1.30.x stable line and re-baseline the "drop-in" claim against it. This is the most important outstanding item. |
| **CVE-2026-56434** (High) — SSI use-after-free | Fix is in the proxied-response path (`ngx_http_request.c`), not the SSI module. Same drift problem. | Same as above. Reachable only with `ssi` + `proxy_pass` + `proxy_buffering off`, none of which the default config enables. |



---

## What surprised me

I thought it would be easier to choose which CVE to address, but it required continuous research throughout the process. I started with the version bump, but when I moved on to address the second CVE through backporting, I was concerned that I might need to choose a different CVE to work on through version bump, though that turned out not to be the case.

Additionally, I was sure that backporting would be more complex than version bump, but in retrospect, it was simpler and resulted in far fewer lines in the build process. I aware to the fact it might differ between cases and each CVE has its best-practice fixing method.

If I had more time, I would have run HTTPS scenarios in the Python test to verify that the first CVE was indeed resolved. In addition, I would have addressed the critical CVE-2026-42533.


---

## AI tool usage

I used Claude Code to complete the task. It was very useful for exploring a domain that was new to me, and for its ability to run tests quickly. I defined the instructions and the logic, and it helped me implement them. Naturally, it makes mistakes along the way—mistakes that can cascade—which required me to verify why it did what it did, as well as correct its errors when necessary
