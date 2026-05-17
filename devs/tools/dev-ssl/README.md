# dev-ssl — local HTTPS / HTTP/3 testing

CLI and container wiring for **end-to-end tests of automatic HTTP/3 upgrades** (Alt-Svc) in a real browser.

Crate serves HTTP/2 over TLS, advertises HTTP/3 via an **`Alt-Svc`** response header, and listens for QUIC on UDP. Browsers that trust the certificate may upgrade later requests to HTTP/3 without changing the URL.

Generated artifacts live in `tmp/` (gitignored). The repo root `.gitignore` excludes `devs/tools/dev-ssl/`.

## Defaults

| Setting | Default |
|---------|---------|
| TLS hostname | `crate.local` (override with `--hostname` or `DEV_SSL_HOSTNAME`) |
| LAN IPv4 in cert | auto-detected on `generate` (override with `--lan-ip`, or `--no-lan-ip`) |
| Crate port | `4200` |
| Host publish port | `8443` (use `443` + `--sudo` for Chrome Alt-Svc) |

## Setup

```bash
chmod +x devs/tools/dev-ssl/cli.sh
devs/tools/dev-ssl/cli.sh --help
```

## Two flows

| Flow | What | Typical URL |
|------|------|-------------|
| **A — local** | Maven package → `tmp/crate/bin/crate` on `:4200` | `https://crate.local:4200/` |
| **B — container** | OCI image; host port → Crate `:4200` inside | `https://crate.local:443/` with `--publish-port 443` |

Flow A is enough for **`curl --http3-only`** and Firefox direct HTTP/3. Flow B is required for **Chrome automatic Alt-Svc upgrade** (see below).

---

## Testing HTTP/3 properly

There are two different things people call “HTTP/3 testing”:

| Goal | What you exercise | Typical setup |
|------|-------------------|---------------|
| **Protocol works** | Client speaks QUIC to Crate’s UDP listener | Flow A + `curl --http3-only`, or Firefox on `:4200` |
| **Auto-upgrade (Alt-Svc)** | Browser reads `Alt-Svc: h3=":…"`, then switches to QUIC on a later request | Flow B on host **:443**, trusted CA, hostname in cert SAN |

Integration tests in the repo cover the protocol; **browser Alt-Svc behaviour is environment-sensitive** — use this tool and the checklist below.

### How Alt-Svc upgrade works here

```text
1. Browser ──TLS HTTP/2──► https://crate.local:443/
   Response includes:  Alt-Svc: h3=":443"; ma=86400

2. Browser ──QUIC HTTP/3──► crate.local:443/udp  (same host, advertised port)
   Host :443 is published into the container as Crate :4200 (TCP + UDP).
```

`cli.sh container run` with `--publish-port 443` sets `-Chttp.quic.alt_svc.port=443` while Crate still listens on **4200** inside the container. Without that, the `Alt-Svc` header would advertise `:4200`, which **Chromium ignores** (see prerequisites).

### Prerequisites (Alt-Svc auto-upgrade in Chrome)

Work through these in order. Skipping one usually looks like “stuck on HTTP/2” with no obvious error.

#### 1. Hostname resolves and matches the certificate

- Run `./cli.sh generate` (or reuse `tmp/` from a previous generate).
- The server cert SAN must include the name you type in the address bar (`crate.local` by default, plus `localhost`).
- **Do not use `https://localhost:443/`** for Alt-Svc testing in Chromium unless `localhost` is what you generated and you understand the caveats below — use the **same hostname as the cert CN/SAN** (default: `crate.local`).

Map the name if it does not resolve:

```text
# /etc/hosts  (or LAN DNS)
127.0.0.1   crate.local
```

For LAN testing, use the machine’s LAN IP instead of `127.0.0.1`, and include that IP in the cert (`--lan-ip` or auto-detection on `generate`).

**IPv6:** If the hostname has a AAAA record but QUIC only listens on IPv4, the browser may try IPv6 first and fail. Prefer `/etc/hosts` with IPv4, or `network.dns.ipv4OnlyDomains` in Firefox, or host-network + `--lan-ipv6` (see `./cli.sh --help`).

#### 2. Dev CA trusted (not the server cert)

Import **`tmp/ca.pem`** (or `tmp/ca.der` in Firefox) into the **Certificate Authorities** store — **not** as a server exception.

| Browser | Where | Extra notes |
|---------|--------|-------------|
| **Firefox** | Settings → Privacy & Security → Certificates → View Certificates → **Authorities** → Import `tmp/ca.pem` | With a custom dev CA, set `about:config` → `network.http.http3.disable_when_third_party_roots_found` = **`false`**, or Firefox may stay on HTTP/2 even when `curl --http3-only` works. |
| **Chrome / Chromium** | OS trust store (varies by platform) or `chrome://settings/security` → Manage certificates → Authorities | **Fully trusted CA required** — any certificate warning blocks Alt-Svc upgrade. No “proceed anyway” for HTTP/3 testing. |

After `./cli.sh generate --rotate-ca`, remove old **“Crate Dev CA”** entries and re-import. Compare fingerprint with `./cli.sh generate` output or `tmp/ca.fingerprint.txt`.

If Firefox shows **`SEC_ERROR_BAD_SIGNATURE`**, delete all old “Crate Dev CA” entries and import `tmp/ca.der`.

#### 3. Advertised Alt-Svc port is in the “lower port” range

**Chromium only follows `Alt-Svc` for QUIC when the advertised port is &lt; 1024** (e.g. **443**). If the header says `h3=":4200"` or `h3=":8443"`, Chrome keeps using HTTP/2.

| Setup | Alt-Svc advertises | Chrome auto-upgrade |
|-------|--------------------|---------------------|
| Flow A, `:4200` | `:4200` | No |
| Flow B, default `:8443` → `:4200` | `:8443` | No |
| Flow B, `--publish-port 443 --sudo` | `:443` | Yes (if 1–2 satisfied) |

Crate setting: `http.quic.alt_svc.port` (set automatically by `cli.sh` when publish port &lt; 1024).

#### 4. Privileged host port 443 is actually bound

Crate cannot bind port 443 as an unprivileged user. Use the container publish path:

```bash
./cli.sh --publish-port 443 --sudo container run
```

This maps host **443/tcp** and **443/udp** → container **4200**. QUIC must reach the same host port advertised in `Alt-Svc`.

#### 5. TLS + HTTP/3 enabled on the server

The container image / `cli.sh run` already sets:

- `ssl.http.enabled=true`
- `http.quic.enabled=true`
- keystore from `tmp/keystore.p12`

Check Crate logs for: `HTTP/3 (QUIC) listening on UDP port … (Alt-Svc h3 port …)`.

#### 6. `localhost` and Chromium

- **`localhost` in the URL** often behaves differently from a “real” hostname (certificate expectations, secure context, Alt-Svc caching).
- For **repeatable Alt-Svc e2e tests**, use a dedicated name (**`crate.local`**) in `/etc/hosts`, matching `./cli.sh generate`.
- **`127.0.0.1`** in the URL does not match a DNS SAN of `crate.local` — use the hostname, not the IP, unless you generated the cert with that IP in SAN (`--lan-ip`).

### Quick start — Alt-Svc / Chrome

```bash
cd devs/tools/dev-ssl

./cli.sh generate
# Import tmp/ca.pem into browser Authorities (see table above)

./cli.sh container build
./cli.sh --publish-port 443 --sudo container run

# /etc/hosts: 127.0.0.1 crate.local
# Open: https://crate.local/   (no port in URL — implies :443)
```

### Quick start — protocol only (`curl` / Firefox on :4200)

```bash
./cli.sh generate
./cli.sh build
./cli.sh run

./cli.sh verify
curl -k --http3-only https://crate.local:4200/ -o /dev/null -w 'http_version=%{http_version}\n'
```

`verify` checks the cert files, TLS handshake, `Alt-Svc` header, and attempts HTTP/3 with curl.

### Verifying in the browser

**Chrome / Chromium**

1. Open `https://crate.local/` (trusted cert, no warnings).
2. DevTools → Network: first document may be **h2**, later reloads **h3** (after Alt-Svc is cached).
3. `chrome://net-internals/#alt-svc` — entry for your host, port **443**.
4. `chrome://net-internals/#http3` — active QUIC sessions.

**Firefox**

1. Same URL; with dev CA, set `network.http.http3.disable_when_third_party_roots_found = false`.
2. DevTools → Network → Protocol column (h2 vs h3).
3. `about:networking#http3` for QUIC sessions.

### Verifying from the command line

```bash
# Alt-Svc on the HTTP/2 response (note the port number)
curl -k -sD- -o /dev/null -I https://crate.local:443/ | grep -i alt-svc

# Direct HTTP/3 (does not test Alt-Svc upgrade, only QUIC)
curl -k --http3-only https://crate.local:443/ -o /dev/null -w 'http_version=%{http_version}\n'

# Full smoke test
./cli.sh verify
```

Expect `Alt-Svc: h3=":443"; ma=86400` when using `--publish-port 443`.

### Common failures

| Symptom | Likely cause |
|---------|----------------|
| Chrome stays on h2 | Alt-Svc port ≥ 1024, or cert not fully trusted, or wrong URL (`:4200`, `localhost`, IP vs SAN) |
| `curl --http3-only` works, browser does not | Firefox third-party root policy; Chrome cert warning; Alt-Svc port |
| QUIC works on LAN IP, not hostname | IPv6 AAAA vs IPv4-only QUIC bind; fix `/etc/hosts` or DNS |
| `SEC_ERROR_BAD_SIGNATURE` (Firefox) | Stale CA in trust store after re-generate |
| Connection refused on :443 | Container not running, or missing `--sudo` for publish 443 |
| Alt-Svc shows `:4200` on Chrome test | Not using `--publish-port 443`, or flow A only |

### Port mapping reference

```text
Browser ──HTTPS/QUIC──► host :443 ──► container :4200 (Crate http.port)
                              Alt-Svc: h3=":443"
```

Default without sudo: host **:8443** → container **:4200** (fine for TLS/h2 smoke tests, **not** for Chrome Alt-Svc).

---

## Commands

```
./cli.sh [global options] <command>

Global options:
  --hostname <name>       TLS CN and DNS SAN (default: crate.local)
  --lan-ip <ip>           Optional IP SAN (auto-detected on generate if omitted)
  --no-lan-ip             Skip LAN IPv4 auto-detection
  --port <port>           Crate listen port (default: 4200)
  --publish-port <port>   Host HTTPS/QUIC port (default: 8443; use 443 for Chrome)
  --runtime podman|docker
  --sudo                  Re-exec as root to bind host :443

  generate                CA + keystore → tmp/
  build                   ./mvnw package → tmp/crate/
  run [--rebuild]         Local bin/crate on --port
  verify                  Certs + live HTTPS/HTTP/3 on --port
  container build         Maven + OCI image (Dockerfile.dist)
  container run           Publish host :publish-port → :4200
  container up            compose (optional)
  container start         generate + build + run
  clean [--dist] [--container-image]
```

Environment: `DEV_SSL_HOSTNAME`, `DEV_SSL_LAN_IP`, `DEV_SSL_LAN_IPV6`, `PUBLISH_PORT`, `NETWORK_HOST`, `CONTAINER_HOST_NETWORK`, …

## Layout

```text
devs/tools/dev-ssl/
  cli.sh                 # entry point
  tmp/                   # generated (gitignored)
  container/
    Dockerfile.dist      # local HTTP/3 build (used by container build)
    Dockerfile             # official crate image + keystore
    docker-compose.yml
```
