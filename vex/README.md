# VEX attestation

```bash
make vex-demo
```

## Why this exists

CVE-2026-60005 is genuinely fixed in this image — the upstream patch is backported onto the
nginx 1.25.5 source (`build/patches/CVE-2026-60005.patch`). But **the scanners still report it**,
because Trivy and Grype match vulnerabilities by *package name + version*, and the version string
is deliberately unchanged at `1.25.5-1echo1`. Only the source was patched.

That is not a scanner bug — it is the expected consequence of backporting, and the reason VEX
(Vulnerability Exploitability eXchange) exists. `CVE-2026-60005.openvex.json` is a machine-readable
attestation stating "this CVE does not apply to this build, and here's why."

## Verified result

| Scanner | Without VEX | With VEX |
|---|---|---|
| Grype 0.117.0 | CVE-2026-60005 reported | **suppressed** |
| Trivy 0.74.0 | CVE-2026-60005 reported | **suppressed** |

It suppresses *only* that CVE — nginx-package findings drop 6 → 5, total findings 191 → 190.
The other five nginx CVEs (including CVE-2026-42533 and CVE-2023-44487) are still reported, which
is correct: they are not fixed in this build.

## Format and status

[OpenVEX](https://openvex.dev) v0.2.0 — chosen because it is the one VEX format **both** Grype and
Trivy support. (Trivy also accepts CycloneDX VEX and CSAF; Grype does not.)

Status is **`fixed`** rather than `not_affected`. OpenVEX defines `fixed` as "the vulnerability
has been remediated in this product," which is exactly true here — the vulnerable code path was
patched. `not_affected` would be the wrong claim: it means the vulnerable code is present but
unreachable, and would require a justification such as `vulnerable_code_not_present`.

## Product identification — the fiddly part

A VEX statement is silently ignored if its product identifier doesn't match how the scanner
identifies the artifact. There is no error message and no warning — the CVE simply keeps
appearing, which looks identical to the VEX not being read at all. Each candidate form was
therefore tested against both scanners rather than assumed:

| `products[].@id` | Grype | Trivy |
|---|---|---|
| `pkg:oci/nginx-echo` (OCI purl, no digest) | **yes** | **yes** |
| `nginx-echo:1.25-bookworm` (image reference) | yes | **no** |
| `pkg:deb/debian/nginx@1.25.5-1echo1?...` (package purl) | yes | not tested |
| `pkg:oci/nginx-echo@sha256:<imageID>` | no | not tested |
| `pkg:oci/nginx-echo@sha256:<manifestDigest>` | no | not tested |
| `sha256:<imageID>` | no | not tested |

`pkg:oci/nginx-echo` is the only form verified to work in **both**, so it is the one used. The
image-reference form is a Grype-only match — a document using just that would suppress the CVE in
Grype while silently failing in Trivy, with no indication anything was wrong.

The digest forms fail because this image exists only locally and has no registry repo digest for
the scanner to compare against. They would likely work for a pushed image.

The package purl is attached as a `subcomponent` so the statement is scoped to the specific nginx
package rather than asserting something about the whole image.

## Known limitation

Identifying the product by mutable tag (`nginx-echo:1.25-bookworm`) is pragmatic but brittle — the
tag can be reassigned to a different image, and the attestation would then apply to something it
was never reviewed against. For a real deployment this should be pinned to the image's registry
digest once pushed. Left as-is here because the image is never pushed to a registry.
