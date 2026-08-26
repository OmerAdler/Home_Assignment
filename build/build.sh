#!/usr/bin/env sh
# build/build.sh — builds nginx 1.25.5 from source inside debian:bookworm-slim,
# linked against an OpenSSL that already fixes CVE-2024-6119,
# CVE-2026-60005 is fixed through backporting with patch command.
# it is packaged as a .deb file.

set -eu

NGINX_VERSION="${NGINX_VERSION:-1.25.5}"
NGINX_SHA256="2fe2294f8af4144e7e842eaea884182a84ee7970e11046ba98194400902bbec0"
PKG_REVISION="1echo1"
MIN_FIXED_OPENSSL="3.0.14-1~deb12u2"

WORK=/build/work
PKGROOT=/Build/pkgroot
OUT=/build/out
mkdir -p "$WORK" "$PKGROOT/DEBIAN" "$OUT"

echo "==> Installing build dependencies (pulls current libssl-dev from bookworm-security)"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential  curl ca-certificates patch \
    libpcre2-dev zlib1g-dev libssl-dev dpkg-dev

echo "==> Verifying the linked OpenSSL already fixes CVE-2024-6119"
INSTALLED_OPENSSL="$(dpkg-query -W -f='${Version}' libssl3)"
echo "    libssl3 installed: $INSTALLED_OPENSSL (fix threshold: $MIN_FIXED_OPENSSL)"
if dpkg --compare-versions "$INSTALLED_OPENSSL" lt "$MIN_FIXED_OPENSSL"; then
    echo "    FATAL: libssl3 $INSTALLED_OPENSSL is older than the CVE-2024-6119 fix ($MIN_FIXED_OPENSSL)." >&2
    echo "    Add/enable the bookworm-security apt source and retry." >&2
    exit 1
fi

echo "==> Fetching nginx $NGINX_VERSION source"
cd "$WORK"
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tar.gz
echo "$NGINX_SHA256  nginx.tar.gz" | sha256sum -c -
tar -xzf nginx.tar.gz
cd "nginx-${NGINX_VERSION}"

echo "==> Applying backport patches"
# Each patch is named after the CVE it fixes. These port fixes from newer
# upstream nginx commits onto the version we ship, for CVEs where no fixed
# Debian package exists to bump to. Fail loudly rather than silently shipping
# an unpatched binary - same principle as the OpenSSL version assertion above.

if ! ls /build/patches/*.patch >/dev/null 2>&1; then
    echo "    FATAL: no patches found in /build/patches." >&2
    echo "    The backport fix would be silently skipped. Check that" >&2
    echo "    build/Dockerfile does 'COPY patches /build/patches'." >&2
    exit 1
fi
APPLIED_PATCHES=""
for p in /build/patches/*.patch; do
    name="$(basename "$p")"
    echo "    applying $name"
    patch -p1 --batch --forward < "$p"
    APPLIED_PATCHES="${APPLIED_PATCHES}${APPLIED_PATCHES:+, }${name%.patch}"
done
echo "    applied: $APPLIED_PATCHES"

echo "==> Configuring (flags mirror nginx.org's own build of nginx:1.25-bookworm exactly)"
./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx --group=nginx \
    --with-compat --with-file-aio --with-threads \
    --with-http_addition_module --with-http_auth_request_module --with-http_dav_module \
    --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module \
    --with-http_mp4_module --with-http_random_index_module --with-http_realip_module \
    --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module \
    --with-http_stub_status_module --with-http_sub_module --with-http_v2_module \
    --with-http_v3_module --with-mail --with-mail_ssl_module --with-stream \
    --with-stream_realip_module --with-stream_ssl_module --with-stream_ssl_preread_module

echo "==> Compiling"
make -j"$(nproc)"

echo "==> Staged install into $PKGROOT"
make install DESTDIR="$PKGROOT"

echo "==> Matching upstream nginx:1.25-bookworm's file layout exactly"
# 'make install' lays out more, and different, files than nginx.org's own package ships:
# backup *.default copies of every conf file, fastcgi.conf, the koi-*/win-utf charset
# maps, and an /etc/nginx/html dir — none of which exist in the real image (verified via
# `docker run --rm --entrypoint sh nginx:1.25-bookworm -c "ls -la /etc/nginx"`).

rm -f "$PKGROOT"/etc/nginx/*.default
rm -f "$PKGROOT/etc/nginx/fastcgi.conf" "$PKGROOT/etc/nginx/koi-utf" \
      "$PKGROOT/etc/nginx/koi-win" "$PKGROOT/etc/nginx/win-utf"
rm -rf "$PKGROOT/etc/nginx/html"

mkdir -p "$PKGROOT/etc/nginx/conf.d" \
         "$PKGROOT/usr/lib/nginx/modules" \
         "$PKGROOT/usr/share/nginx/html" \
         "$PKGROOT/var/cache/nginx"
ln -s /usr/lib/nginx/modules "$PKGROOT/etc/nginx/modules"

# runtime config: the exact content nginx.org ships in the original image (see
# Step 1b — extracted once via `docker cp`, committed to build/pkg-overlay/)
cp /build/pkg-overlay/etc/nginx/nginx.conf "$PKGROOT/etc/nginx/nginx.conf"
cp /build/pkg-overlay/etc/nginx/conf.d/default.conf "$PKGROOT/etc/nginx/conf.d/default.conf"

# stock nginx welcome pages — same files 'make install' would have used, just at the
# path the original image actually serves them from (/usr/share/nginx/html, per
# default.conf's "root" directive, not the source tree's own --html-path default)
cp html/index.html html/50x.html "$PKGROOT/usr/share/nginx/html/"

echo "==> Recording build-time evidence (linked OpenSSL, for the README CVE table)"
# NOTE: deliberately NOT /usr/share/doc/nginx - debian:bookworm-slim ships
# "path-exclude /usr/share/doc/*" in /etc/dpkg/dpkg.cfg.d/docker, so dpkg would
# silently drop this file on install and the evidence would never reach the image.
mkdir -p "$PKGROOT/usr/share/nginx"
{
    echo "nginx version : $NGINX_VERSION"
    echo "built (chroot): $(date -u +%FT%TZ)"
    echo "libssl3       : $INSTALLED_OPENSSL  (CVE-2024-6119 fixed by version bump)"
    echo "patches       : $APPLIED_PATCHES  (backported onto $NGINX_VERSION)"
    ldd "$PKGROOT/usr/sbin/nginx"
} > "$PKGROOT/usr/share/nginx/build-info.txt"
cat "$PKGROOT/usr/share/nginx/build-info.txt"

echo "==> Writing DEBIAN/control"
DEB_VERSION="${NGINX_VERSION}-${PKG_REVISION}"
cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: nginx
Version: ${DEB_VERSION}
Section: httpd
Priority: optional
Architecture: amd64
Depends: libssl3 (>= ${MIN_FIXED_OPENSSL}), libpcre2-8-0, zlib1g, libc6
Maintainer: Omer Adler
Description: nginx ${NGINX_VERSION} rebuilt from source with CVE fixes
 Rebuild of nginx ${NGINX_VERSION} from upstream source with two remediations:
 CVE-2024-6119 fixed by bumping the linked system OpenSSL, and CVE-2026-60005
 fixed by backporting upstream commit 0cca8e05 onto ${NGINX_VERSION}.
 Applied patches: ${APPLIED_PATCHES}
EOF

echo "==> Building .deb"
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT/nginx_${DEB_VERSION}_amd64.deb"
echo "==> Done: $OUT/nginx_${DEB_VERSION}_amd64.deb"
