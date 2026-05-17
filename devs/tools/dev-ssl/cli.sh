#!/usr/bin/env bash
# Unified CLI for local Crate HTTPS / HTTP/3 development TLS.
set -euo pipefail

DEV_SSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_NAME="$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "${DEV_SSL_DIR}/../../.." && pwd)"
OUT_DIR="${DEV_SSL_DIR}/tmp"
CRATE_DIST_DIR="${OUT_DIR}/crate"
CONTAINER_DIR="${DEV_SSL_DIR}/container"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"

TLS_HOSTNAME="${DEV_SSL_HOSTNAME:-crate.local}"
LAN_IP="${DEV_SSL_LAN_IP:-}"
LAN_IPV6="${DEV_SSL_LAN_IPV6:-}"
SKIP_LAN_IP_DETECT="${SKIP_LAN_IP_DETECT:-false}"
TLS_HOSTNAME_CLI_SET=false
LAN_IP_CLI_SET=false
HTTP_PORT="${HTTP_PORT:-4200}"
# Host port published to the container; Crate listens on HTTP_PORT inside (default 4200).
PUBLISH_PORT="${PUBLISH_PORT:-8443}"
CONTAINER_HTTP_PORT="${HTTP_PORT}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-keystorePassword}"
VALIDITY_DAYS="${VALIDITY_DAYS:-825}"
IMAGE="${IMAGE:-crate-http3-dev}"
HEAP_SIZE="${CRATE_HEAP_SIZE:-512m}"
HBA_TRUST_CIDR="${HBA_TRUST_CIDR:-0.0.0.0/0}"
# Crate network.host: 0.0.0.0 = all interfaces. _site_ = RFC1918 IPv4 only (not ULA IPv6).
# For LAN IPv6 use _site:ipv4_,_global:ipv6_ or explicit IPs (see resolve_network_host).
NETWORK_HOST="${NETWORK_HOST:-0.0.0.0}"
# host = Crate uses the host network stack (bind LAN v4+v6 on the host; no port publish)
CONTAINER_HOST_NETWORK="${CONTAINER_HOST_NETWORK:-false}"
USE_SUDO=false
ROTATE_CA=false
# jlink-jdk is not a Maven dependency of app; package it before app assembly.
MVN_JLINK_MODULE="jlink-jdk"
MVN_APP_MODULE="app"
# Must match versions.jdk in the repository root pom.xml.
CRATE_JAVA_MAJOR=26

usage() {
  local cli="${CLI_NAME}"
  cat <<EOF
Usage: ${cli} [global options] <command> [command options]

Local TLS + Crate HTTP/3 dev helper.
Generated files: ${OUT_DIR}/   (certs, keystore, extracted package)

Global options:
  -h, --help              Show this help
  --hostname <name>       TLS CN and DNS SAN (default: ${TLS_HOSTNAME})
  --lan-ip <ip>           Optional IP SAN (auto-detected on generate if omitted)
  --lan-ipv6 <ip>         Optional IPv6 for network.host with --host-network
  --no-lan-ip             Do not auto-detect a LAN IPv4 for the cert SAN
  --port <port>           HTTP port for local run/verify (default: ${HTTP_PORT})
  --publish-port <port>   Host HTTPS port (→ container :${CONTAINER_HTTP_PORT}, default: ${PUBLISH_PORT})
  --runtime <cmd>         OCI CLI: podman or docker (default: ${CONTAINER_RUNTIME})
  --sudo                  Re-exec as root for container commands (bind host :443)
  --password <secret>     Keystore password (default: keystorePassword)
  --image <name>          Container image tag (default: ${IMAGE})
  --rotate-ca             Force a new dev CA (default: reuse tmp/ca.key across generate)

Commands:
  generate                Create CA + keystore in tmp/
  build                   ./mvnw package → extract to tmp/crate/
  run [--rebuild]         Start tmp/crate/bin/crate (builds via mvn if missing)
  clean [--dist] [--container-image]  Remove tmp/, tmp/crate/, and/or OCI image
  verify                  Check certs and live HTTPS/HTTP/3 on --port
  container build         mvn package + ${CONTAINER_RUNTIME} build (HTTP/3 distro)
  container run           Run OCI container (host :${PUBLISH_PORT} → :${CONTAINER_HTTP_PORT})
  container up            compose up (official crate image + mounted keystore)
  container start         generate + build + run (one shot)

================================================================================
FLOW A — Local package + bin/crate (port ${HTTP_PORT}, good for dev / curl)
================================================================================

  cd devs/tools/dev-ssl

  # 1) Dev TLS (once, or after hostname change)
  ./${cli} generate
  # optional: ./${cli} --hostname crate.local --lan-ip 10.0.0.5 generate
  #    Import tmp/ca.pem into browser → Authorities

  # 2) Build Crate distribution with Maven (from repo root via ./mvnw)
  #    Produces app/target/crate-*.tar.gz and unpacks to tmp/crate/
  ./${cli} build
  #    Equivalent: ./mvnw package -DskipTests -pl ${MVN_JLINK_MODULE}
  #               ./mvnw package -DskipTests -pl ${MVN_APP_MODULE} -am
  #               (then jlink-jdk-*.zip → tmp/crate/jdk/)
  #    Binary:     tmp/crate/bin/crate
  #    Bundled JDK: tmp/crate/jdk/bin/java

  # 3) Start Crate (exec tmp/crate/bin/crate with SSL + HTTP/3)
  ./${cli} run
  #    After server code changes:
  ./${cli} run --rebuild

  # 4) Smoke test
  ./${cli} verify
  #    Browser: https://${TLS_HOSTNAME}:${HTTP_PORT}/

================================================================================
FLOW B — OCI container (runtime: ${CONTAINER_RUNTIME}, host :${PUBLISH_PORT} → :${CONTAINER_HTTP_PORT})
================================================================================

  cd devs/tools/dev-ssl

  # 1) Dev TLS (same as flow A)
  ./${cli} generate
  #    Import tmp/ca.pem into browser → Authorities

  # 2) Maven package + OCI image (uses tmp/crate/ as build context)
  ./${cli} container build
  #    ${CONTAINER_RUNTIME} build -f container/Dockerfile.dist -t ${IMAGE} tmp/crate/

  # 3) Run container (default host :${PUBLISH_PORT}, no root needed)
  ./${cli} container run
  #    Browser: https://${TLS_HOSTNAME}:${PUBLISH_PORT}/

  # Use docker instead of podman:
  ./${cli} --runtime docker container build
  ./${cli} --runtime docker container run

  # Chrome-friendly: HTTPS on https://${TLS_HOSTNAME}/ (host :443 → container :${HTTP_PORT})
  ./${cli} --publish-port 443 --sudo container run

  # One-shot:
  ./${cli} container start

================================================================================
Other
================================================================================

  ./${cli} clean                  # remove tmp/ + container image
  ./${cli} clean --dist           # only tmp/crate/
  ./${cli} clean --container-image   # only OCI image ${IMAGE}

Browser / HTTP/3 testing: see devs/tools/dev-ssl/README.md (Alt-Svc prerequisites, CA trust, port < 1024).

  https://${TLS_HOSTNAME}:${HTTP_PORT}/        flow A — curl / Firefox h3; Chrome ignores Alt-Svc
  https://${TLS_HOSTNAME}:${PUBLISH_PORT}/     flow B default :8443 → :${HTTP_PORT} (no Chrome Alt-Svc)
  https://${TLS_HOSTNAME}/                      flow B — --publish-port 443 --sudo (Chrome Alt-Svc)

Host :443: ./${cli} container build && ./${cli} --publish-port 443 --sudo container run
  (sudo run rebuilds image in root podman store from tmp/crate/; jlink jdk/ is copied, not host symlinks)
Never sudo container build (root-owned jlink-jdk/target)

Environment:
  DEV_SSL_HOSTNAME, DEV_SSL_LAN_IP, DEV_SSL_LAN_IPV6, HTTP_PORT, PUBLISH_PORT, NETWORK_HOST, CONTAINER_HOST_NETWORK, CONTAINER_RUNTIME, KEYSTORE_PASSWORD, IMAGE, CRATE_HEAP_SIZE, JAVA_HOME
  JDK: Java ${CRATE_JAVA_MAJOR} (matches pom.xml). Host: archlinux-java set java-${CRATE_JAVA_MAJOR}-temurin. Container: eclipse-temurin:${CRATE_JAVA_MAJOR}-jre.

EOF
}

container_usage() {
  local cli="${CLI_NAME}"
  cat <<EOF
Usage: ${cli} [global options] container <subcommand>

OCI flow (FLOW B) — runtime: ${CONTAINER_RUNTIME} (override with --runtime or CONTAINER_RUNTIME).
Host :\${PUBLISH_PORT:-${PUBLISH_PORT}} → container :${CONTAINER_HTTP_PORT} (Crate http.port).

Subcommands:
  build       ./mvnw package (jlink-jdk, then app), then \${CONTAINER_RUNTIME} build → ${IMAGE}
  run         publish host :<port> → :${CONTAINER_HTTP_PORT} (+ :${CONTAINER_HTTP_PORT} for HTTP/3 when using :443)
  up          \${CONTAINER_RUNTIME} compose up (official crate image, keystore from tmp/)
  start       generate + build + run

Step by step:

  ./${cli} generate
  ./${cli} container build
  ./${cli} container run            # https://${TLS_HOSTNAME}:${PUBLISH_PORT}/

  ./${cli} --runtime docker container build
  ./${cli} --runtime docker container run

  ./${cli} --publish-port 443 --sudo container run

Or:

  ./${cli} container start

Trust ${OUT_DIR}/ca.pem before opening https://${TLS_HOSTNAME}:<publish-port>/

EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "$*" >&2
}

require_container_runtime() {
  if ! command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
    die "OCI runtime not found: ${CONTAINER_RUNTIME} (install it or set CONTAINER_RUNTIME=docker|podman)"
  fi
}

# Run the configured OCI CLI (podman, docker, …).
cr() {
  require_container_runtime
  "${CONTAINER_RUNTIME}" "$@"
}

# compose subcommand (podman compose / docker compose).
cr_compose() {
  require_container_runtime
  "${CONTAINER_RUNTIME}" compose "$@"
}

require_keystore() {
  [[ -f "${OUT_DIR}/keystore.p12" ]] || die "missing ${OUT_DIR}/keystore.p12 — run: ${CLI_NAME} generate"
}

detect_lan_ipv4() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  fi
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ "${ip}" == "127.0.0.1" ]] && ip=""
  echo "${ip}"
}

resolve_tls_defaults_for_generate() {
  if [[ "${SKIP_LAN_IP_DETECT}" != "true" && -z "${LAN_IP}" ]]; then
    LAN_IP="$(detect_lan_ipv4)"
    if [[ -n "${LAN_IP}" ]]; then
      info "Detected LAN IPv4 for cert SAN: ${LAN_IP}"
    fi
  fi
}

load_saved_tls_identity() {
  if [[ "${TLS_HOSTNAME_CLI_SET}" != "true" && -f "${OUT_DIR}/hostname.txt" ]]; then
    TLS_HOSTNAME="$(cat "${OUT_DIR}/hostname.txt")"
  fi
  if [[ "${LAN_IP_CLI_SET}" != "true" && -f "${OUT_DIR}/lan_ip.txt" ]]; then
    LAN_IP="$(cat "${OUT_DIR}/lan_ip.txt")"
  fi
  if [[ -f "${OUT_DIR}/lan_ipv6.txt" ]]; then
    LAN_IPV6="$(cat "${OUT_DIR}/lan_ipv6.txt")"
  fi
}

ca_fingerprint() {
  openssl x509 -in "${OUT_DIR}/ca.pem" -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/sha256 Fingerprint=//;s/://g'
}

sync_keystore_to_dist() {
  if [[ ! -f "${OUT_DIR}/keystore.p12" ]]; then
    return 0
  fi
  if [[ -d "${CRATE_DIST_DIR}" ]]; then
    mkdir -p "${CRATE_DIST_DIR}/config"
    cp "${OUT_DIR}/keystore.p12" "${CRATE_DIST_DIR}/config/keystore.p12"
    info "Updated ${CRATE_DIST_DIR}/config/keystore.p12"
  fi
}

print_browser_trust_notes() {
  local fp
  fp="$(ca_fingerprint)"
  cat <<EOF

HTTP/3 / Alt-Svc testing guide: ${DEV_SSL_DIR}/README.md

Trust this CA (Authorities — not the server cert):
  ${OUT_DIR}/ca.pem
  ${OUT_DIR}/ca.der   (Firefox: use if SEC_ERROR_BAD_SIGNATURE)

CA SHA-256 fingerprint:
  ${fp}

If you re-ran generate without --rotate-ca, the CA is unchanged — no re-import needed.
If you used --rotate-ca or still see SEC_ERROR_BAD_SIGNATURE:
  1. Remove every old "Crate Dev CA" from browser Authorities
  2. Import ca.pem or ca.der above (trust for websites)
  3. ${CLI_NAME} container build && restart the container

Chrome Alt-Svc auto-upgrade checklist:
  - Hostname resolves and matches cert SAN (default: ${TLS_HOSTNAME}; add to /etc/hosts)
  - CA fully trusted (no cert warnings — required for Chromium)
  - Alt-Svc advertises port < 1024 → use: ${CLI_NAME} --publish-port 443 --sudo container run
  - Open https://${TLS_HOSTNAME}/  (avoid localhost for repeatable Chromium tests)

Firefox + dev CA: about:config → network.http.http3.disable_when_third_party_roots_found = false

Verify: ${CLI_NAME} verify
  curl -k -sD- -o /dev/null -I https://${TLS_HOSTNAME}:443/ | grep -i alt-svc

EOF
}

cmd_clean_dist() {
  if [[ -e "${CRATE_DIST_DIR}" ]]; then
    info "Removing ${CRATE_DIST_DIR}"
    rm -rf "${CRATE_DIST_DIR}"
  fi
}

cmd_clean_container_image() {
  require_container_runtime
  if cr image inspect "${IMAGE}" >/dev/null 2>&1; then
    info "Removing ${CONTAINER_RUNTIME} image ${IMAGE}"
    cr rmi "${IMAGE}"
  else
    info "No ${CONTAINER_RUNTIME} image ${IMAGE}"
  fi
}

cmd_clean() {
  local clean_dist=false clean_image=false clean_all=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dist)
        clean_dist=true
        clean_all=false
        shift
        ;;
      --container-image|--podman)
        clean_image=true
        clean_all=false
        shift
        ;;
      *)
        die "unknown clean option: $1 (supported: --dist, --container-image)"
        ;;
    esac
  done

  if [[ "${clean_all}" == "true" ]]; then
    if [[ -d "${OUT_DIR}" ]]; then
      info "Removing ${OUT_DIR}/"
      rm -rf "${OUT_DIR}"
    else
      info "Nothing to clean (${OUT_DIR} does not exist)"
    fi
    cmd_clean_container_image
    return 0
  fi

  if [[ "${clean_dist}" == "true" ]]; then
    cmd_clean_dist
  fi
  if [[ "${clean_image}" == "true" ]]; then
    cmd_clean_container_image
  fi
}

# bin/crate expects ${CRATE_DIST_DIR}/jdk/bin/java.
# Partial mvn -pl app builds omit jdk/ in the tarball (assembly needs jlink-jdk in-reactor);
# we merge jlink-jdk/target/jlink-jdk-*.zip after extract.
# Prefer Temurin/Java ${CRATE_JAVA_MAJOR} from the host when set, else jlink from the build.
java_major_version() {
  local java_bin="$1"
  "${java_bin}" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1
}

java_home_candidates() {
  local seen="" home
  if [[ -n "${JAVA_HOME:-}" ]]; then
    echo "${JAVA_HOME}"
    seen="${JAVA_HOME}"
  fi
  if command -v java >/dev/null 2>&1; then
    home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    if [[ -n "${home}" && "${home}" != "${seen}" ]]; then
      echo "${home}"
    fi
  fi
}

link_crate_jdk_from_home() {
  local home="$1"
  [[ -x "${home}/bin/java" ]] || return 1
  [[ "$(java_major_version "${home}/bin/java")" == "${CRATE_JAVA_MAJOR}" ]] || return 1
  info "Linking Java ${CRATE_JAVA_MAJOR} (${home}) → ${CRATE_DIST_DIR}/jdk"
  rm -rf "${CRATE_DIST_DIR}/jdk"
  ln -sfn "${home}" "${CRATE_DIST_DIR}/jdk"
}

install_crate_jdk_from_jlink() {
  local jdk_zip
  jdk_zip="$(ls -1 "${REPO_ROOT}/jlink-jdk/target"/jlink-jdk-*.zip 2>/dev/null | sort -V | tail -1)"
  [[ -n "${jdk_zip}" ]] || return 1
  info "==> install bundled JDK from ${jdk_zip}"
  rm -rf "${CRATE_DIST_DIR}/jdk"
  mkdir -p "${CRATE_DIST_DIR}/jdk"
  unzip -q -o "${jdk_zip}" -d "${CRATE_DIST_DIR}/jdk"
  [[ -x "${CRATE_DIST_DIR}/jdk/bin/java" ]] || die "unexpected layout in ${jdk_zip} (expected bin/java)"
}

# Host JDK symlinks work for ./cli.sh run on the machine, but COPY into OCI images keeps the
# symlink — /crate/jdk then points at /usr/lib/jvm/... which does not exist in the container.
materialize_crate_jdk() {
  local ver
  if [[ -L "${CRATE_DIST_DIR}/jdk" ]]; then
    info "Replacing host JDK symlink with jlink bundle (required for container images)"
    rm -rf "${CRATE_DIST_DIR}/jdk"
  elif [[ -x "${CRATE_DIST_DIR}/jdk/bin/java" ]]; then
    ver="$(java_major_version "${CRATE_DIST_DIR}/jdk/bin/java")"
    if [[ "${ver}" == "${CRATE_JAVA_MAJOR}" ]]; then
      return 0
    fi
    info "Replacing ${CRATE_DIST_DIR}/jdk (Java ${ver:-?}, want ${CRATE_JAVA_MAJOR})"
    rm -rf "${CRATE_DIST_DIR}/jdk"
  fi
  install_crate_jdk_from_jlink || die "missing jlink JDK — run: ${CLI_NAME} container build"
  ver="$(java_major_version "${CRATE_DIST_DIR}/jdk/bin/java")"
  [[ "${ver}" == "${CRATE_JAVA_MAJOR}" ]] || die "jlink JDK is Java ${ver:-?}, want ${CRATE_JAVA_MAJOR}"
}

ensure_crate_jdk() {
  local ver home
  if [[ -x "${CRATE_DIST_DIR}/jdk/bin/java" ]]; then
    ver="$(java_major_version "${CRATE_DIST_DIR}/jdk/bin/java")"
    if [[ "${ver}" == "${CRATE_JAVA_MAJOR}" ]]; then
      return 0
    fi
    info "Replacing ${CRATE_DIST_DIR}/jdk (Java ${ver:-?}, want ${CRATE_JAVA_MAJOR})"
    rm -rf "${CRATE_DIST_DIR}/jdk"
  fi
  while IFS= read -r home; do
    [[ -n "${home}" ]] || continue
    if link_crate_jdk_from_home "${home}"; then
      return 0
    fi
  done < <(java_home_candidates)
  if install_crate_jdk_from_jlink; then
    ver="$(java_major_version "${CRATE_DIST_DIR}/jdk/bin/java")"
    [[ "${ver}" == "${CRATE_JAVA_MAJOR}" ]] || die "jlink JDK is Java ${ver:-?}, want ${CRATE_JAVA_MAJOR} — rebuild jlink-jdk or use java-${CRATE_JAVA_MAJOR}-temurin"
    return 0
  fi
  die "missing Java ${CRATE_JAVA_MAJOR} for ${CRATE_DIST_DIR}/jdk — archlinux-java set java-${CRATE_JAVA_MAJOR}-temurin, or: ${CLI_NAME} build"
}

ensure_jlink_target_writable() {
  local target="${REPO_ROOT}/jlink-jdk/target"
  [[ -d "${target}" ]] || return 0
  if [[ -w "${target}" ]] && { [[ ! -e "${target}/maven-jlink" ]] || [[ -w "${target}/maven-jlink" ]]; }; then
    return 0
  fi
  info "jlink-jdk/target is not writable (often after 'sudo … container build')"
  if sudo chown -R "$(id -u)":"$(id -g)" "${target}"; then
    info "Fixed ownership of ${target}"
    return 0
  fi
  die "fix permissions: sudo chown -R $(id -un):$(id -gn) ${target}"
}

# Incremental app builds can leave multiple crate-6.4.0-<timestamp>-*.jar in lib/ → jar hell.
prune_stale_crate_jars() {
  local lib="${CRATE_DIST_DIR}/lib"
  local -a stamped=()
  local f base
  for f in "${lib}"/crate-*.jar; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    # crate-6.4.0-2026-05-15-16-53-1e80f55.jar (mvn tarball.version, not plain crate-server-*.jar)
    if [[ "${base}" =~ ^crate-[0-9]+\.[0-9]+\.[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}- ]]; then
      stamped+=("${f}")
    fi
  done
  if [[ ${#stamped[@]} -le 1 ]]; then
    return 0
  fi
  local keep
  keep="$(printf '%s\n' "${stamped[@]}" | sort -V | tail -1)"
  info "Pruning ${#stamped[@]} stamped crate jars in lib/ (keeping $(basename "${keep}"))"
  for f in "${stamped[@]}"; do
    [[ "${f}" == "${keep}" ]] || rm -f "${f}"
  done
}

verify_crate_lib() {
  local lib="${CRATE_DIST_DIR}/lib"
  local -a left=()
  local f base
  for f in "${lib}"/crate-*.jar; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    if [[ "${base}" =~ ^crate-[0-9]+\.[0-9]+\.[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}- ]]; then
      left+=("${base}")
    fi
  done
  if [[ ${#left[@]} -gt 1 ]]; then
    die "jar hell risk: multiple stamped crate jars in lib/: ${left[*]}"
  fi
}

NETTY_HTTP_TRANSPORT_SRC="${REPO_ROOT}/server/src/main/java/org/elasticsearch/http/netty4/Netty4HttpServerTransport.java"

warn_if_stale_crate_dist() {
  [[ -f "${NETTY_HTTP_TRANSPORT_SRC}" ]] || return 0
  [[ -d "${CRATE_DIST_DIR}/lib" ]] || return 0
  local jar
  jar="$(find "${CRATE_DIST_DIR}/lib" -maxdepth 1 -name 'crate-*.jar' -type f 2>/dev/null | sort -V | tail -1)"
  [[ -n "${jar}" ]] || return 0
  if [[ "${NETTY_HTTP_TRANSPORT_SRC}" -nt "${jar}" ]]; then
    info "Crate sources are newer than ${CRATE_DIST_DIR}/lib — HTTP/3 fixes need: ${CLI_NAME} container build"
  fi
}

# _site_ omits ULA (fd00::/8); use LAN_IPV6 or _site:ipv4_ + _global:ipv6_ (separate -C flags).
resolve_network_host() {
  if [[ "${CONTAINER_HOST_NETWORK}" != "true" ]]; then
    return 0
  fi
  if [[ -n "${LAN_IPV6}" ]]; then
    NETWORK_HOST="${LAN_IP},${LAN_IPV6}"
    info "host network: network.host=${LAN_IP},${LAN_IPV6}"
    return 0
  fi
  if [[ "${NETWORK_HOST}" == "_site_" ]]; then
    info "network.host=_site_ is IPv4-only in Java; using _site:ipv4_,_global:ipv6_ (set --lan-ipv6 for explicit ULA)"
    NETWORK_HOST="_site:ipv4_,_global:ipv6_"
  fi
}

container_crate_args() {
  # Chrome ignores Alt-Svc when the advertised h3 port is >= 1024 (QUIC may still listen on CONTAINER_HTTP_PORT).
  local listen_port="${CONTAINER_HTTP_PORT}"
  local alt_svc_port="${CONTAINER_HTTP_PORT}"
  if [[ "${CONTAINER_HOST_NETWORK}" == "true" ]]; then
    listen_port="${PUBLISH_PORT}"
    alt_svc_port="${PUBLISH_PORT}"
  elif [[ "${PUBLISH_PORT}" -lt 1024 ]]; then
    alt_svc_port="${PUBLISH_PORT}"
  fi
  CONTAINER_CRATE_ARGS=(
    /crate/bin/crate
    -Cdiscovery.type=single-node
    -Cpath.data=/tmp/crate-data
    -Cpath.logs=/tmp/crate-logs
    -Cnetwork.host="${NETWORK_HOST}"
    -Chttp.port="${listen_port}"
    -Chttp.quic.alt_svc.port="${alt_svc_port}"
    -Chttp.quic.enabled=true
    -Cssl.http.enabled=true
    -Cssl.keystore_filepath=/crate/config/keystore.p12
    -Cssl.keystore_password="${KEYSTORE_PASSWORD}"
    -Cssl.keystore_key_password="${KEYSTORE_PASSWORD}"
    -Cauth.host_based.config.10.user=crate
    -Cauth.host_based.config.10.address=0.0.0.0/0
    -Cauth.host_based.config.10.method=trust
  )
}

run_mvn_package() {
  ensure_jlink_target_writable
  info "==> ./mvnw package -DskipTests -pl ${MVN_JLINK_MODULE}"
  (cd "${REPO_ROOT}" && ./mvnw package -DskipTests -pl "${MVN_JLINK_MODULE}" -q)
  info "==> ./mvnw clean package -DskipTests -pl ${MVN_APP_MODULE} -am"
  (cd "${REPO_ROOT}" && ./mvnw clean package -DskipTests -pl "${MVN_APP_MODULE}" -am -q)
}

# Extract app/target/crate-*.tar.gz into ${CRATE_DIST_DIR} (tmp/crate/).
# Args: force rebuild when "true".
cmd_build() {
  local force="${1:-false}"

  if [[ "${force}" != "true" && -x "${CRATE_DIST_DIR}/bin/crate" ]]; then
    ensure_crate_jdk
    prune_stale_crate_jars
    info "Using existing distribution at ${CRATE_DIST_DIR}"
    return 0
  fi

  cmd_clean_dist

  run_mvn_package

  local tarball staging extracted
  tarball="$(ls -1 "${REPO_ROOT}/app/target"/crate-*.tar.gz 2>/dev/null | sort -V | tail -1)"
  [[ -n "${tarball}" ]] || die "no crate-*.tar.gz in app/target — mvn package failed?"

  info "==> extract ${tarball} → ${CRATE_DIST_DIR}"
  staging="$(mktemp -d)"
  tar xzf "${tarball}" -C "${staging}"
  extracted="$(find "${staging}" -maxdepth 1 -type d -name 'crate-*' | head -1)"
  [[ -n "${extracted}" ]] || die "unexpected tarball layout in ${tarball}"
  mv "${extracted}" "${CRATE_DIST_DIR}"
  rm -rf "${staging}"

  if [[ -f "${OUT_DIR}/keystore.p12" ]]; then
    mkdir -p "${CRATE_DIST_DIR}/config"
    cp "${OUT_DIR}/keystore.p12" "${CRATE_DIST_DIR}/config/keystore.p12"
  fi

  ensure_crate_jdk
  prune_stale_crate_jars
  verify_crate_lib
  info "Crate distribution ready at ${CRATE_DIST_DIR}"
}

resolve_crate_bin() {
  local force_build="${1:-false}"

  if [[ -n "${CRATE_HOME:-}" && -x "${CRATE_HOME}/bin/crate" ]]; then
    echo "${CRATE_HOME}/bin/crate"
    return
  fi
  if [[ -x "./bin/crate" ]]; then
    echo "$(pwd)/bin/crate"
    return
  fi

  cmd_build "${force_build}"
  [[ -x "${CRATE_DIST_DIR}/bin/crate" ]] || die "missing ${CRATE_DIST_DIR}/bin/crate after build"
  echo "${CRATE_DIST_DIR}/bin/crate"
}

cmd_generate() {
  mkdir -p "${OUT_DIR}"
  cmd_clean_dist
  resolve_tls_defaults_for_generate

  local ca_action="create"
  if [[ -f "${OUT_DIR}/ca.key" && -f "${OUT_DIR}/ca.pem" && "${ROTATE_CA}" != "true" ]]; then
    ca_action="reuse"
  fi

  echo "Generating dev TLS for TLS_HOSTNAME=${TLS_HOSTNAME} LAN_IP=${LAN_IP:-<none>} → ${OUT_DIR} (CA: ${ca_action})"

  # Subshell contains temp dir lifetime (avoid RETURN trap + set -u unbound workdir)
  (
    set -euo pipefail
    local workdir
    workdir="$(mktemp -d)"

    if [[ "${ca_action}" == "reuse" ]]; then
      cp "${OUT_DIR}/ca.key" "${workdir}/ca.key"
      cp "${OUT_DIR}/ca.pem" "${workdir}/ca.pem"
      [[ -f "${OUT_DIR}/ca.srl" ]] && cp "${OUT_DIR}/ca.srl" "${workdir}/ca.srl"
    else
      openssl genrsa -out "${workdir}/ca.key" 2048
      openssl req -new -key "${workdir}/ca.key" -out "${workdir}/ca.csr" \
        -subj "/CN=Crate Dev CA/O=CrateDB Dev SSL/C=DE"

      cat > "${workdir}/ca.ext" <<'EOF'
[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF

      openssl x509 -req -in "${workdir}/ca.csr" -signkey "${workdir}/ca.key" \
        -out "${workdir}/ca.pem" -days 3650 \
        -extfile "${workdir}/ca.ext" -extensions v3_ca
    fi

    openssl genrsa -out "${workdir}/server.key" 2048
    openssl req -new -key "${workdir}/server.key" -out "${workdir}/server.csr" \
      -subj "/CN=${TLS_HOSTNAME}"

    local san_index=1 san_lines=""
    san_lines+="DNS.${san_index} = ${TLS_HOSTNAME}"$'\n'
    san_index=$((san_index + 1))
    san_lines+="DNS.${san_index} = localhost"$'\n'
    san_index=$((san_index + 1))
    if [[ -n "${LAN_IP}" ]]; then
      san_lines+="IP.${san_index} = ${LAN_IP}"$'\n'
    fi

    cat > "${workdir}/server.ext" <<EOF
[ server ]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ alt_names ]
${san_lines}
EOF

    local -a sign_ca_args=(-CA "${workdir}/ca.pem" -CAkey "${workdir}/ca.key")
    if [[ -f "${workdir}/ca.srl" ]]; then
      sign_ca_args+=(-CAserial "${workdir}/ca.srl")
    else
      sign_ca_args+=(-CAcreateserial)
    fi

    openssl x509 -req -in "${workdir}/server.csr" \
      "${sign_ca_args[@]}" \
      -out "${workdir}/server.crt" -days "${VALIDITY_DAYS}" \
      -extfile "${workdir}/server.ext" -extensions server

    openssl verify -CAfile "${workdir}/ca.pem" "${workdir}/server.crt"

    openssl pkcs12 -export \
      -in "${workdir}/server.crt" \
      -inkey "${workdir}/server.key" \
      -certfile "${workdir}/ca.pem" \
      -out "${OUT_DIR}/keystore.p12" \
      -name crate-dev \
      -passout "pass:${KEYSTORE_PASSWORD}"

    cp "${workdir}/ca.key" "${OUT_DIR}/ca.key"
    cp "${workdir}/ca.pem" "${OUT_DIR}/ca.pem"
    cp "${workdir}/server.crt" "${OUT_DIR}/server.crt"
    [[ -f "${workdir}/ca.srl" ]] && cp "${workdir}/ca.srl" "${OUT_DIR}/ca.srl"
    echo "${TLS_HOSTNAME}" > "${OUT_DIR}/hostname.txt"
    echo "${LAN_IP}" > "${OUT_DIR}/lan_ip.txt"
    if [[ -n "${LAN_IPV6}" ]]; then
      echo "${LAN_IPV6}" > "${OUT_DIR}/lan_ipv6.txt"
    fi

    rm -rf "${workdir}"
  )

  openssl x509 -in "${OUT_DIR}/ca.pem" -outform DER -out "${OUT_DIR}/ca.der"
  ca_fingerprint > "${OUT_DIR}/ca.fingerprint.txt"

  sync_keystore_to_dist

  echo ""
  echo "OK — created:"
  echo "  ${OUT_DIR}/keystore.p12"
  echo "  ${OUT_DIR}/ca.pem / ca.der   (import into browser Authorities)"
  if [[ "${ca_action}" == "reuse" ]]; then
    echo "  (reused existing CA — browsers that already trust it need no re-import)"
  fi
  print_browser_trust_notes
  echo "Next — pick one flow:"
  echo ""
  echo "  Flow A (local bin/crate on :${HTTP_PORT}):"
  echo "    ${CLI_NAME} build"
  echo "    ${CLI_NAME} run"
  echo ""
  echo "  Flow B (container, runtime ${CONTAINER_RUNTIME}, host :${PUBLISH_PORT}):"
  echo "    ${CLI_NAME} container build"
  echo "    ${CLI_NAME} container run"
  echo "    # Chrome HTTP/3: ${CLI_NAME} --publish-port 443 --sudo container run"
  echo ""
  echo "Open https://${TLS_HOSTNAME}:${HTTP_PORT}/ (flow A) or https://${TLS_HOSTNAME}:${PUBLISH_PORT}/ (flow B)"
  echo "  (add to /etc/hosts if needed: 127.0.0.1 ${TLS_HOSTNAME})"
}

cmd_run() {
  local rebuild=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild)
        rebuild=true
        shift
        ;;
      *)
        die "unknown run option: $1 (supported: --rebuild)"
        ;;
    esac
  done

  require_keystore
  local crate_bin
  crate_bin="$(resolve_crate_bin "${rebuild}")"
  local crate_home
  crate_home="$(cd "$(dirname "${crate_bin}")/.." && pwd)"

  resolve_network_host
  info "Starting ${crate_bin} on https://0.0.0.0:${HTTP_PORT}/ (network.host=${NETWORK_HOST})"
  cd "${crate_home}"
  exec "${crate_bin}" \
    -Cdiscovery.type=single-node \
    -Cnetwork.host="${NETWORK_HOST}" \
    -Chttp.port="${HTTP_PORT}" \
    -Chttp.quic.enabled=true \
    -Cssl.http.enabled=true \
    -Cssl.keystore_filepath="${OUT_DIR}/keystore.p12" \
    -Cssl.keystore_password="${KEYSTORE_PASSWORD}" \
    -Cssl.keystore_key_password="${KEYSTORE_PASSWORD}" \
    -Cauth.host_based.config.10.user=crate \
    -Cauth.host_based.config.10.address="${HBA_TRUST_CIDR}" \
    -Cauth.host_based.config.10.method=trust
}

cmd_verify() {
  require_keystore

  echo "=== Local file chain ==="
  openssl verify -CAfile "${OUT_DIR}/ca.pem" "${OUT_DIR}/server.crt"

  echo ""
  echo "=== Certificate SANs ==="
  openssl x509 -in "${OUT_DIR}/server.crt" -noout -subject -ext subjectAltName

  echo ""
  echo "=== Live TLS ${TLS_HOSTNAME}:${HTTP_PORT} ==="
  if ! openssl s_client -connect "${TLS_HOSTNAME}:${HTTP_PORT}" -servername "${TLS_HOSTNAME}" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null; then
    die "could not connect to ${TLS_HOSTNAME}:${HTTP_PORT} — is Crate running?"
  fi

  echo ""
  echo "=== Dev CA fingerprint (compare with browser import) ==="
  if [[ -f "${OUT_DIR}/ca.fingerprint.txt" ]]; then
    cat "${OUT_DIR}/ca.fingerprint.txt"
  else
    ca_fingerprint || true
  fi

  echo ""
  echo "=== Alt-Svc + HTTP/3 ==="
  curl -k -sD- -o /dev/null -I "https://${TLS_HOSTNAME}:${HTTP_PORT}/" | grep -i alt-svc || echo "(no alt-svc)"
  if curl -k --http3-only "https://${TLS_HOSTNAME}:${HTTP_PORT}/" -o /dev/null -w 'http_version=%{http_version}\n' 2>/dev/null; then
    :
  else
    echo "(curl --http3-only failed — need curl with HTTP/3)"
  fi
}

cmd_container_image_only() {
  require_keystore
  [[ -x "${CRATE_DIST_DIR}/bin/crate" ]] \
    || die "missing ${CRATE_DIST_DIR} — run: ${CLI_NAME} container build"
  materialize_crate_jdk
  prune_stale_crate_jars
  verify_crate_lib
  cr rmi -f "${IMAGE}" >/dev/null 2>&1 || true
  info "==> ${CONTAINER_RUNTIME} build --no-cache -f container/Dockerfile.dist -t ${IMAGE}"
  cr build --no-cache -f "${CONTAINER_DIR}/Dockerfile.dist" -t "${IMAGE}" "${CRATE_DIST_DIR}"
}

cmd_container_build() {
  reexec_with_sudo_if_needed build
  require_keystore
  cmd_build true
  cmd_container_image_only
  info "Built ${IMAGE} — run: ${CLI_NAME} container run"
}

reexec_with_sudo_if_needed() {
  local subcmd="${1:?}"
  [[ "${USE_SUDO}" == "true" ]] || return 0
  [[ -n "${DEV_SSL_AS_ROOT:-}" ]] && return 0
  if [[ "${CONTAINER_HOST_NETWORK}" == "true" ]]; then
    info "Re-exec with sudo (host network, Crate listens on host :${PUBLISH_PORT})"
  else
    info "Re-exec with sudo to bind privileged host port ${PUBLISH_PORT} (Crate listens on :${CONTAINER_HTTP_PORT} in the container)"
  fi
  exec sudo -E \
    DEV_SSL_AS_ROOT=1 \
    DEV_SSL_HOSTNAME="${TLS_HOSTNAME}" \
    DEV_SSL_LAN_IP="${LAN_IP}" \
    DEV_SSL_LAN_IPV6="${LAN_IPV6}" \
    HTTP_PORT="${HTTP_PORT}" \
    PUBLISH_PORT="${PUBLISH_PORT}" \
    NETWORK_HOST="${NETWORK_HOST}" \
    CONTAINER_HOST_NETWORK="${CONTAINER_HOST_NETWORK}" \
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME}" \
    IMAGE="${IMAGE}" \
    KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD}" \
    CRATE_HEAP_SIZE="${HEAP_SIZE}" \
    HBA_TRUST_CIDR="${HBA_TRUST_CIDR}" \
    CONTAINER_UID="${CONTAINER_UID}" \
    CONTAINER_GID="${CONTAINER_GID}" \
    "${DEV_SSL_DIR}/${CLI_NAME}" \
    --hostname "${TLS_HOSTNAME}" \
    --lan-ip "${LAN_IP}" \
    ${LAN_IPV6:+--lan-ipv6 "${LAN_IPV6}"} \
    --publish-port "${PUBLISH_PORT}" \
    --runtime "${CONTAINER_RUNTIME}" \
    --image "${IMAGE}" \
    --password "${KEYSTORE_PASSWORD}" \
    container "${subcmd}"
}

warn_privileged_publish_port() {
  if [[ "${PUBLISH_PORT}" -ge 1024 ]]; then
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  if [[ "${USE_SUDO}" == "true" ]]; then
    return 0
  fi
  info "Host port ${PUBLISH_PORT} is privileged — rootless ${CONTAINER_RUNTIME} cannot bind it."
  info "  ${CLI_NAME} --publish-port ${PUBLISH_PORT} --sudo container run"
  info "  ${CLI_NAME} --publish-port ${PUBLISH_PORT} --sudo container start   # sudo binds host :443 only"
  info "Or use default :8443: ${CLI_NAME} container run"
}

container_port_maps() {
  # Host :443/tcp+udp → container :4200 (Alt-Svc advertises :443 via http.quic.alt_svc.port).
  # Publish on [::] too so QUIC works when the hostname resolves to IPv6.
  PORT_MAPS=(
    -p "${PUBLISH_PORT}:${CONTAINER_HTTP_PORT}/tcp"
    -p "${PUBLISH_PORT}:${CONTAINER_HTTP_PORT}/udp"
    -p "[::]:${PUBLISH_PORT}:${CONTAINER_HTTP_PORT}/tcp"
    -p "[::]:${PUBLISH_PORT}:${CONTAINER_HTTP_PORT}/udp"
  )
}

cmd_container_run() {
  reexec_with_sudo_if_needed run
  resolve_network_host
  cr rm -f crate-http3 >/dev/null 2>&1 || true
  warn_privileged_publish_port
  # sudo/root podman uses a different image store than rootless — rebuild from tmp/crate/.
  if [[ -n "${DEV_SSL_AS_ROOT:-}" ]] || [[ "$(id -u)" -eq 0 ]]; then
    warn_if_stale_crate_dist
    info "Rootful ${CONTAINER_RUNTIME}: rebuilding ${IMAGE} from ${CRATE_DIST_DIR}"
    info "  (only repackages tmp/crate — run '${CLI_NAME} container build' after server code changes)"
    cmd_container_image_only
  fi
  local -a port_maps=()
  if [[ "${CONTAINER_HOST_NETWORK}" == "true" ]]; then
    info "==> ${CONTAINER_RUNTIME} run --network=host (https://${TLS_HOSTNAME}:${PUBLISH_PORT}/, network.host=${NETWORK_HOST})"
    info "    Crate binds on the host (v4 + ULA v6)"
  else
    container_port_maps
    port_maps=("${PORT_MAPS[@]}")
    info "==> ${CONTAINER_RUNTIME} run (https://${TLS_HOSTNAME}:${PUBLISH_PORT}/ → :${CONTAINER_HTTP_PORT}, network.host=${NETWORK_HOST})"
    if [[ "${PUBLISH_PORT}" != "${CONTAINER_HTTP_PORT}" ]]; then
      info "    Alt-Svc advertises h3=\":${PUBLISH_PORT}\" (QUIC UDP ${PUBLISH_PORT}→:${CONTAINER_HTTP_PORT}, incl. [::]:${PUBLISH_PORT})"
    fi
  fi
  info "    trust ${OUT_DIR}/ca.pem in the browser"
  require_container_runtime
  container_crate_args
  local -a run_flags=(-e CRATE_DISABLE_GC_LOGGING=1)
  if [[ "${CONTAINER_HOST_NETWORK}" == "true" ]]; then
    run_flags+=(--network=host)
    run_flags+=(--user "${CONTAINER_UID}:${CONTAINER_GID}")
    # Crate refuses to run as root; CAP_NET_BIND_SERVICE lets UID 1000 bind host :443.
    if [[ "${PUBLISH_PORT}" -lt 1024 ]]; then
      run_flags+=(--cap-add=NET_BIND_SERVICE)
    fi
  else
    run_flags+=(--user "${CONTAINER_UID}:${CONTAINER_GID}")
  fi
  info "Running: ${CONTAINER_RUNTIME} run --rm ${run_flags[*]} ${port_maps[*]:-} ${IMAGE} …"
  exec "${CONTAINER_RUNTIME}" run --rm \
    "${run_flags[@]}" \
    ${port_maps[@]+"${port_maps[@]}"} \
    --name crate-http3 \
    "${IMAGE}" \
    "${CONTAINER_CRATE_ARGS[@]}"
}

cmd_container_up() {
  reexec_with_sudo_if_needed up
  require_keystore
  warn_privileged_publish_port
  info "==> ${CONTAINER_RUNTIME} compose up (https://${TLS_HOSTNAME}:${PUBLISH_PORT}/)"
  export PUBLISH_PORT CONTAINER_UID CONTAINER_GID
  require_container_runtime
  exec "${CONTAINER_RUNTIME}" compose -f "${CONTAINER_DIR}/docker-compose.yml" up
}

cmd_container_start() {
  cmd_generate
  cmd_container_build
  cmd_container_run
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local command=""
  local -a args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --hostname)
        [[ $# -ge 2 ]] || die "--hostname requires a value"
        TLS_HOSTNAME="$2"
        TLS_HOSTNAME_CLI_SET=true
        shift 2
        ;;
      --lan-ip)
        [[ $# -ge 2 ]] || die "--lan-ip requires a value"
        LAN_IP="$2"
        LAN_IP_CLI_SET=true
        shift 2
        ;;
      --no-lan-ip)
        SKIP_LAN_IP_DETECT=true
        LAN_IP=""
        LAN_IP_CLI_SET=true
        shift
        ;;
      --lan-ipv6)
        [[ $# -ge 2 ]] || die "--lan-ipv6 requires a value"
        LAN_IPV6="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires a value"
        HTTP_PORT="$2"
        CONTAINER_HTTP_PORT="${HTTP_PORT}"
        shift 2
        ;;
      --publish-port)
        [[ $# -ge 2 ]] || die "--publish-port requires a value"
        PUBLISH_PORT="$2"
        shift 2
        ;;
      --password)
        [[ $# -ge 2 ]] || die "--password requires a value"
        KEYSTORE_PASSWORD="$2"
        shift 2
        ;;
      --image)
        [[ $# -ge 2 ]] || die "--image requires a value"
        IMAGE="$2"
        shift 2
        ;;
      --runtime)
        [[ $# -ge 2 ]] || die "--runtime requires a value"
        CONTAINER_RUNTIME="$2"
        shift 2
        ;;
      --sudo)
        USE_SUDO=true
        shift
        ;;
      --rotate-ca)
        ROTATE_CA=true
        shift
        ;;
      generate|build|run|clean|verify|container|podman)
        command="$1"
        if [[ "${command}" == "podman" ]]; then
          info "note: 'podman' is an alias for 'container' (CONTAINER_RUNTIME=${CONTAINER_RUNTIME})"
          command="container"
        fi
        shift
        args=("$@")
        break
        ;;
      *)
        die "unknown option or command: $1 (try ${CLI_NAME} --help)"
        ;;
    esac
  done

  [[ -n "${command}" ]] || { usage >&2; exit 1; }

  load_saved_tls_identity

  case "${command}" in
    generate)
      [[ ${#args[@]} -eq 0 ]] || die "unexpected arguments: ${args[*]}"
      cmd_generate
      ;;
    build)
      [[ ${#args[@]} -eq 0 ]] || die "unexpected arguments: ${args[*]}"
      cmd_build true
      ;;
    run)
      cmd_run "${args[@]}"
      ;;
    clean)
      cmd_clean "${args[@]}"
      ;;
    verify)
      [[ ${#args[@]} -eq 0 ]] || die "unexpected arguments: ${args[*]}"
      cmd_verify
      ;;
    container)
      [[ ${#args[@]} -ge 1 ]] || { container_usage >&2; exit 1; }
      local sub="${args[0]}"
      local sub_args=()
      if [[ ${#args[@]} -gt 1 ]]; then
        sub_args=("${args[@]:1}")
      fi
      case "${sub}" in
        build)
          [[ ${#sub_args[@]} -eq 0 ]] || die "unexpected arguments: ${sub_args[*]}"
          cmd_container_build
          ;;
        run)
          [[ ${#sub_args[@]} -eq 0 ]] || die "unexpected arguments: ${sub_args[*]}"
          cmd_container_run
          ;;
        up)
          [[ ${#sub_args[@]} -eq 0 ]] || die "unexpected arguments: ${sub_args[*]}"
          cmd_container_up
          ;;
        start)
          [[ ${#sub_args[@]} -eq 0 ]] || die "unexpected arguments: ${sub_args[*]}"
          cmd_container_start
          ;;
        -h|--help)
          container_usage
          exit 0
          ;;
        *)
          container_usage >&2
          die "unknown container subcommand: ${sub}"
          ;;
      esac
      ;;
    *)
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"
