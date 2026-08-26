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

## Build

Requires Docker. Everything compiles inside containers — nothing is installed on the host.

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
`Containerfile`. See [Residual risk](#residual-risk) on njs.

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
```
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
(upstream), [`baseline-grype-post-fix.txt`](baseline-grype-post-fix.txt) /
[`baseline-trivy-post-fix.txt`](baseline-trivy-post-fix.txt) (this image, no VEX),
[`grype-post-fix.txt`](grype-post-fix.txt) / [`trivy-post-fix.txt`](trivy-post-fix.txt)
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
| **CVE-2023-44487** (High, KEV, EPSS 100%) — HTTP/2 Rapid Reset | **Already fixed.** nginx shipped the mitigation in **1.25.3**; we build 1.25.5. Scanners flag it on package metadata alone. | Emit a second VEX statement with `not_affected`. Cheap, and removes the scariest-looking finding honestly. |

**Also outstanding:**

- **8 OpenSSL CVEs remain**, including CVE-2026-14456 (High). Debian bookworm has no fix; the same
  backport-vs-bump analysis would apply, but fixing them means building OpenSSL from source, which
  is a large scope increase.
- **njs is not shipped.** Upstream sets `NJS_VERSION=0.8.4` and ships `nginx-module-njs` as a
  separate package. No test scenario needs it, but a config using `js_*` directives would work on
  upstream and fail here. This is the most likely source of a real-world drop-in surprise.
- **No TLS/HTTP2/HTTP3 coverage** in the test — neither image ships a certificate. This is the gap
  I'd close first: it's the code path the OpenSSL bump actually touches. The test proves the bump
  didn't *break* anything, not that handshakes work.
- **VEX identifies the product by mutable tag.** Should be pinned to a registry digest once pushed.
- **`patch --forward` accepts fuzz.** A patch applying with fuzz could land in the wrong place. For
  this one-line patch I verified the result by hand; a stricter build would use `--fuzz=0`.

---

## What surprised me

**Renaming the package silently hid six CVEs.** The first build produced a package called
`nginx-echo`. Scanners resolve vulnerabilities by *package name + version*, and no database has
heard of `nginx-echo` — so all six nginx CVEs vanished from the report. Not fixed. **Invisible.**
The scan looked *better* while the image was exactly as vulnerable. Renaming the package back to
`nginx` made them reappear, which felt like a regression and was actually the fix. This is the
thing I'd most want a reviewer to notice: a security artifact can be made to look clean by
accident, and the version-bump result only held up because `libssl3` kept its upstream name.

**VEX product matching fails silently.** A non-matching product identifier produces no error, no
warning, no "0 statements applied" — the CVE just keeps appearing, indistinguishable from the file
never being read. My first attempt used digest-based identifiers and did nothing. Worse, the form I
*had* verified against Grype (`nginx-echo:1.25-bookworm`) is ignored by Trivy, so a document that
looked correct would have half-worked. Only `pkg:oci/nginx-echo` works in both, established by
testing each form against each scanner.

**The advisory named a module the fix doesn't touch.** CVE-2026-60005 is titled "memory disclosure
when using `ngx_http_slice_module`", but `ngx_http_slice_filter_module.c` is unchanged in both
releases that fixed it. The advisory names the *trigger* — `slice` creates subrequests, which is
what reaches the faulty path — not the location. I initially picked this CVE for the wrong reason
("the slice module is a small self-contained file"), and measurement disproved that before it
mattered.

**`debian:bookworm-slim` silently discarded my evidence file.** `build-info.txt` was written to
`/usr/share/doc/nginx/`, and the slim image ships `path-exclude /usr/share/doc/*`. The file was in
the `.deb` and absent from the image, with no error. Moved to `/usr/share/nginx/`.

**Tarball diffs aren't commits.** I first derived the patch by diffing 1.31.2 → 1.31.3 release
tarballs, which conflates every change in the release. Only going to commit level revealed that
CVE-2026-42533 needs six commits while CVE-2026-60005 needs one — which changed which CVE I chose.

## What I'd do differently

- **Pin the base image by digest.** `debian:bookworm-slim` is as mutable as the tag I was careful
  to pin for the baseline. Inconsistent of me.
- **Write the compatibility test earlier.** I built the image first and tested after. Having the
  test first would have made every later change (package rename, backport) verifiable immediately.
- **Test the failure path from the start.** Both times I changed the test's output, checking only
  the passing path hid real bugs — most recently a summary that reported "22 byte-identical" on a
  run where 14 bodies differed.
- **Add a functional test for the patch itself.** The upstream commit ships a reproducer config.
  Running it against patched and unpatched builds would demonstrate the fix *works*, rather than
  only that it *applied*. This is the biggest missing piece of evidence.

---

## AI tool usage

Built with Claude Code, used throughout. Where it helped and where it didn't:

**Helped most — checking assumptions against reality.** The workflow that produced most of the
value was refusing to accept plausible reasoning without evidence. Configure flags came from
`nginx -V` on the actual image, not documentation. The claim that a patch would backport cleanly
came from a `patch --dry-run` against 1.25.5. VEX product identifiers came from testing six forms
against two scanners. Several confident-sounding conclusions were wrong and got caught this way —
including my own initial CVE choice.

**Helped — mechanical work at volume.** Extracting the upstream layout to match byte-for-byte,
writing 23 test scenarios, diffing release tarballs, cloning nginx and bisecting commit ranges.

**Where it hurt — plausible reasoning that was wrong.** The first CVE recommendation ("the slice
module is small and self-contained, so it'll backport cleanly") sounded reasonable and was false:
that file is untouched by the fix. The initial VEX document was written with an unverified product
identifier and silently did nothing. In both cases the error was asserting from pattern-matching
instead of measuring, and both were only caught by testing.

**Where my own review mattered.** Two of the most important findings in this submission came from
me pushing back on the model's output rather than accepting it: questioning why CVE-2026-60005 had
vanished from a post-fix scan (which uncovered the package-rename problem), and questioning whether
a fix in `ngx_http_regex_exec()` could really be the right commit for a CVE titled after the slice
module (which prompted the stable-release cross-check that now anchors the patch's provenance).
