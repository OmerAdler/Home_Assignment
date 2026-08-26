#!/usr/bin/env python3
"""
Compatibility test: proves nginx-echo is a drop-in replacement for nginx:1.25-bookworm.

This is a DIFFERENTIAL test. Both images are booted as separate containers and the
same requests are sent to each; the reference image is the oracle. Nothing is
asserted against hardcoded expected values, so the test stays meaningful even as
upstream details change.

Run:    python test/compat_test.py
Exits:  0 if every scenario matches, 1 on any mismatch.

Stdlib only - no pip install required.
"""

import contextlib
import http.client
import os
import random
import re
import socket
import string
import subprocess
import sys
import time
from dataclasses import dataclass, field

REFERENCE_IMAGE = os.environ.get("REFERENCE_IMAGE", "nginx:1.25-bookworm")
CANDIDATE_IMAGE = os.environ.get("CANDIDATE_IMAGE", "nginx-echo:1.25-bookworm")

CUSTOM_CONF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "custom.conf")

HTTP_DATE = re.compile(
    r"^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$")

# Headers allowed to differ between the two images. Each is a consequence of
# having rebuilt the image, not an incompatibility. They are never skipped: each
# must still be present and match its pattern on BOTH sides.
#   date          - wall-clock time of the response
#   last-modified - static file mtime, i.e. each image's build date
#   etag          - nginx derives it from mtime + size, so it inherits the above

VOLATILE_HEADERS = {
    "date": HTTP_DATE,
    "last-modified": HTTP_DATE,
    "etag": re.compile(r'^"[0-9a-f]+-[0-9a-f]+"$'),
}

STUB_STATUS_SHAPE = re.compile(
    rb"^Active connections: \d+ \nserver accepts handled requests"
    rb"\n \d+ \d+ \d+ \nReading: \d+ Writing: \d+ Waiting: \d+ ?\n$")


# ---------------------------------------------------------------------------
# Scenarios - plain data. `raw` sends bytes over a socket instead of using an
# HTTP client (no client will emit a malformed request line). `body_shape` marks
# a body as legitimately non-deterministic, matched by regex instead of bytes.
# ---------------------------------------------------------------------------

@dataclass
class Scenario:
    name: str
    server: str = "default"          # "default" (:80) or "custom" (:8081)
    method: str = "GET"
    path: str = "/"
    headers: dict = field(default_factory=dict)
    body: bytes | None = None
    raw: bytes | None = None
    body_shape: re.Pattern | None = None


BODY_512KB = b"y" * (512 * 1024)     # under the 1m default
BODY_2MB = b"x" * (2 * 1024 * 1024)  # over the 1m default, under the custom 2m
TEXT = {"Content-Type": "text/plain"}

SCENARIOS = [
    # --- default server (:80), stock config --------------------------------
    Scenario("root: GET /"),
    Scenario("static: GET /50x.html", path="/50x.html"),
    Scenario("404: GET /does-not-exist", path="/does-not-exist"),
    Scenario("HEAD /", method="HEAD"),
    Scenario("method not allowed: POST / (small body)",
             method="POST", body=BODY_512KB, headers=TEXT),
    Scenario("large body: POST / 2MB exceeds client_max_body_size",
             method="POST", body=BODY_2MB, headers=TEXT),
    Scenario("range: GET / bytes=0-99", headers={"Range": "bytes=0-99"}),
    Scenario("conditional: GET / with stale If-None-Match",
             headers={"If-None-Match": '"deadbeef-1"'}),
    Scenario("host header: GET / with unknown Host",
             headers={"Host": "not-localhost.test"}),
    Scenario("long URI: GET /aaa...(9000)", path="/" + "a" * 9000),
    Scenario("oversized header: 10KB X-Big", headers={"X-Big": "z" * 10000}),

    # --- malformed requests, sent as raw bytes -----------------------------
    Scenario("malformed: garbage request line",
             raw=b"\x16\x03\x01GARBAGE\r\n\r\n"),
    Scenario("malformed: bad HTTP version", raw=b"GET / HTTP/9.9\r\n\r\n"),
    Scenario("malformed: missing request target", raw=b"GET\r\n\r\n"),
    Scenario("malformed: bare LF line endings",
             raw=b"GET / HTTP/1.1\nHost: x\n\n"),

    # --- custom config (:8081), from test/custom.conf ----------------------
    Scenario("custom cfg: GET / on custom server", server="custom"),
    Scenario("custom cfg: return 418 /teapot", server="custom", path="/teapot"),
    Scenario("custom cfg: add_header /custom-header",
             server="custom", path="/custom-header"),
    Scenario("custom cfg: sub_filter rewrites body",
             server="custom", path="/subfilter"),
    Scenario("custom cfg: realip module directives accepted",
             server="custom", path="/realip",
             headers={"X-Forwarded-For": "203.0.113.9"}),
    Scenario("custom cfg: raised client_max_body_size accepts 512KB",
             server="custom", method="POST", path="/teapot",
             body=BODY_512KB, headers=TEXT),
    Scenario("custom cfg: 2MB still under raised 2m limit",
             server="custom", method="POST", path="/teapot",
             body=BODY_2MB, headers=TEXT),
    Scenario("custom cfg: stub_status module",
             server="custom", path="/stub_status", body_shape=STUB_STATUS_SHAPE),
]


# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

@dataclass
class Nginx:
    image: str
    name: str
    port: int          # -> container :80
    custom_port: int   # -> container :8081

    def port_for(self, server):
        return self.port if server == "default" else self.custom_port


def free_port():

    """Ask the OS for an unused TCP port so repeat runs never collide."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def running(image, label):

    """Boot `image` with custom.conf mounted in; always clean up on exit."""
    suffix = "".join(random.choices(string.ascii_lowercase, k=6))
    nginx = Nginx(image, f"compat-{label}-{suffix}", free_port(), free_port())
    subprocess.run(
        ["docker", "run", "-d", "--rm", "--name", nginx.name,
         "-p", f"127.0.0.1:{nginx.port}:80",
         "-p", f"127.0.0.1:{nginx.custom_port}:8081",
         "-v", f"{CUSTOM_CONF}:/etc/nginx/conf.d/zz-custom.conf:ro",
         image],
        check=True, capture_output=True)
    try:
        wait_ready(nginx)
        yield nginx
    finally:
        subprocess.run(["docker", "stop", nginx.name],
                       capture_output=True, check=False)


def wait_ready(nginx, timeout=30):
    """Poll both listeners until they serve, so tests never race the boot."""
    deadline = time.time() + timeout
    for port in (nginx.port, nginx.custom_port):
        while True:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                conn.request("GET", "/")
                conn.getresponse().read()
                conn.close()
                break
            except Exception:
                if time.time() > deadline:
                    logs = subprocess.run(["docker", "logs", nginx.name],
                                          capture_output=True, text=True)
                    raise RuntimeError(
                        f"{nginx.image} not ready on port {port}.\n"
                        f"--- container logs ---\n{logs.stdout}\n{logs.stderr}")
                time.sleep(0.2)


# ---------------------------------------------------------------------------
# Sending requests
# ---------------------------------------------------------------------------

@dataclass
class Response:
    status: int | None
    headers: list          # ordered [(lowercased name, value)]
    body: bytes

    @property
    def names(self):
        return [n for n, _ in self.headers]

    def get(self, name):
        return next((v for n, v in self.headers if n == name), None)


def send(nginx, sc):
    port = nginx.port_for(sc.server)
    return send_raw(port, sc.raw) if sc.raw else send_http(port, sc)


def send_http(port, sc):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    try:
        conn.request(sc.method, sc.path, body=sc.body, headers=sc.headers)
        resp = conn.getresponse()
        return Response(resp.status,
                        [(k.lower(), v) for k, v in resp.getheaders()],
                        resp.read())
    finally:
        conn.close()


def send_raw(port, payload):

    """Send bytes verbatim, then parse whatever comes back by hand."""
    with socket.create_connection(("127.0.0.1", port), timeout=15) as s:
        s.sendall(payload)
        chunks = []
        while True:
            try:
                block = s.recv(65536)
            except socket.timeout:
                break
            if not block:
                break
            chunks.append(block)

    head, _, body = b"".join(chunks).partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    if not lines or not lines[0]:
        return Response(None, [], body)

    parts = lines[0].split(" ", 2)
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    headers = [(k.strip().lower(), v.strip())
               for k, _, v in (line.partition(":") for line in lines[1:])
               if v]

    return Response(status, headers, body)


# ---------------------------------------------------------------------------
# Comparison  ("what working correctly means")
# ---------------------------------------------------------------------------
# status ......... must match exactly, always
# header names ... the ordered list must match exactly
# header values .. must match exactly, except VOLATILE_HEADERS (still checked
#                  for presence and well-formedness on both sides)
# body ........... byte-for-byte, unless the scenario declares a body_shape

def compare(ref, cand, body_shape):

    """Return a list of human-readable differences; empty means equivalent."""
    diffs = []

    if ref.status != cand.status:
        diffs.append(f"status: reference={ref.status} candidate={cand.status}")

    if ref.names != cand.names:
        diffs.append(f"headers: {describe_header_diff(ref.names, cand.names)}")
    else:
        diffs += compare_header_values(ref, cand)

    diffs += compare_bodies(ref, cand, body_shape)
    return diffs


def describe_header_diff(ref_names, cand_names):
    missing = [h for h in ref_names if h not in cand_names]
    unexpected = [h for h in cand_names if h not in ref_names]
    if missing or unexpected:
        parts = []
        if missing:
            parts.append(f"missing={missing}")
        if unexpected:
            parts.append(f"unexpected={unexpected}")
        return " ".join(parts)
    return f"order: reference={ref_names} candidate={cand_names}"


def compare_header_values(ref, cand):
    diffs = []
    for name in ref.names:
        ref_val, cand_val = ref.get(name), cand.get(name)
        pattern = VOLATILE_HEADERS.get(name)
        if pattern:
            for who, val in (("reference", ref_val), ("candidate", cand_val)):
                if val is None or not pattern.match(val):
                    diffs.append(f"header {name!r} malformed on {who}: {val!r}")
        elif ref_val != cand_val:
            diffs.append(
                f"header {name!r}: reference={ref_val!r} candidate={cand_val!r}")
    return diffs


def compare_bodies(ref, cand, body_shape):
    if body_shape:
        return [f"body shape mismatch on {who}: {body[:120]!r}"
                for who, body in (("reference", ref.body), ("candidate", cand.body))
                if not body_shape.match(body)]
    if ref.body != cand.body:
        return [f"body differs: reference={len(ref.body)}B "
                f"candidate={len(cand.body)}B\n"
                f"      reference[:200]={ref.body[:200]!r}\n"
                f"      candidate[:200]={cand.body[:200]!r}"]
    return []


# ---------------------------------------------------------------------------

def main():
    print(f"reference : {REFERENCE_IMAGE}")
    print(f"candidate : {CANDIDATE_IMAGE}\n")

    failures = []
    with running(REFERENCE_IMAGE, "ref") as ref, \
         running(CANDIDATE_IMAGE, "cand") as cand:

        print(f"reference on :{ref.port} / :{ref.custom_port}   "
              f"candidate on :{cand.port} / :{cand.custom_port}\n")

        for sc in SCENARIOS:
            try:
                ref_resp = send(ref, sc)
                cand_resp = send(cand, sc)
            except Exception as exc:
                failures.append((sc.name, [f"request raised: {exc!r}"]))
                print(f"  ERROR  {sc.name}")
                continue

            diffs = compare(ref_resp, cand_resp, sc.body_shape)
            if diffs:
                failures.append((sc.name, diffs))
                print(f"  FAIL   {sc.name}")
            else:
                print(f"  ok     {sc.name}  [{ref_resp.status}]")

    print()

    if failures:
        print(f"{len(failures)} of {len(SCENARIOS)} scenarios MISMATCHED:\n")
        for name, diffs in failures:
            print(f"  {name}")
            for d in diffs:
                print(f"      - {d}")
            print()
        return 1

    print(f"All {len(SCENARIOS)} scenarios matched. "
          f"{CANDIDATE_IMAGE} is a drop-in replacement for {REFERENCE_IMAGE}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())