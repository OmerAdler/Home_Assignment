#!/usr/bin/env sh
# build/build.sh — builds nginx 1.25.5 from source inside debian:bookworm-slim,
# linked against an OpenSSL that already fixes CVE-2024-6119, and packages it as a .deb.

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
    build-essential  curl ca-certificates \
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
mkdir -p "$PKGROOT/usr/share/doc/nginx-echo"
{
    echo "nginx version : $NGINX_VERSION"
    echo "built (chroot): $(date -u +%FT%TZ)"
    echo "libssl3       : $INSTALLED_OPENSSL"
    ldd "$PKGROOT/usr/sbin/nginx"
} > "$PKGROOT/usr/share/doc/nginx-echo/build-info.txt"
cat "$PKGROOT/usr/share/doc/nginx-echo/build-info.txt"

echo "==> Writing DEBIAN/control"
DEB_VERSION="${NGINX_VERSION}-${PKG_REVISION}"
cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: nginx-echo
Version: ${DEB_VERSION}
Section: httpd
Priority: optional
Architecture: amd64
Depends: libssl3 (>= ${MIN_FIXED_OPENSSL}), libpcre2-8-0, zlib1g, libc6
Maintainer: Omer Adler
Description: nginx ${NGINX_VERSION} built from source, CVE-2024-6119 fixed via OpenSSL version bump
 Rebuild of nginx ${NGINX_VERSION} from upstream source, linked against a
 system OpenSSL that already contains the CVE-2024-6119 fix.
EOF

echo "==> Building .deb"
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT/nginx-echo_${DEB_VERSION}_amd64.deb"
echo "==> Done: $OUT/nginx-echo_${DEB_VERSION}_amd64.deb"