#!/usr/bin/env bash
# Run the workshop with Docker (the server) or rootless podman (a Fedora laptop). Settings: config.yml
# (copy config.example.yml); without it, everything runs on this computer only, for testing.
#
#   ./ws build                 build the image (R, packages, the prerendered tutorial)
#   ./ws prepare-data          build run/data/synthea-covid19-10k.duckdb once (~13 GB RAM)
#   ./ws setup [options]       participants (from config.yml), passwords and login cards (run/handouts/); see app/setup.R
#   ./ws up                    start; prints the address participants open
#   ./ws down | logs | ps      stop / follow logs / list containers (also the participants' ones)
#   ./ws address               show the address, ports and HTTPS mode from config.yml
#   ./ws test                  run the tests
#   ./ws e2e                   end-to-end test with headless browsers (needs ./ws up; use a fresh ./ws setup --reset)
set -euo pipefail
cd "$(dirname "$0")"

# Inside a toolbox there is no container engine: run this script on the host instead.
if [[ -f /run/.toolboxenv ]]; then
    exec flatpak-spawn --host "$PWD/ws" "$@"
fi

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- config.yml
# A top-level "key: value" from config.yml (comments and quotes removed), or the default.
cfg() {
    local v=""
    [[ -f config.yml ]] && v=$(awk -v k="$1" '
        $0 ~ "^" k ":" { sub("^" k ":[ \t]*", ""); sub("[ \t]+#.*$", ""); sub("^#.*$", ""); gsub(/^["\x27]|["\x27]$/, ""); print; exit }' config.yml)
    echo "${v:-$2}"
}

export WS_WORKSHOP_ID; WS_WORKSHOP_ID=$(cfg workshop omop_explore)
[[ -d "workshops/$WS_WORKSHOP_ID" ]] || die "config.yml: workshop '$WS_WORKSHOP_ID' is not a folder in workshops/"
export WS_MEMORY WS_CPUS WS_IDLE_MS
WS_MEMORY=$(cfg memory 2g); WS_CPUS=$(cfg cpus 2); WS_IDLE_MS=$(( $(cfg idle_minutes 30) * 60000 ))

export WS_HTTP_PORT WS_HTTPS_PORT WS_TLS WS_IP WS_HOSTNAME WS_PUBLIC_URL
WS_HTTP_PORT=$(cfg http_port 80); WS_HTTPS_PORT=$(cfg https_port 443); WS_TLS=$(cfg tls auto)
[[ "$WS_HTTP_PORT" =~ ^[0-9]+$ && "$WS_HTTPS_PORT" =~ ^[0-9]+$ ]] || die "config.yml: http_port and https_port must be numbers"
case "$WS_TLS" in auto|files|off|internal) ;; *) die "config.yml: tls must be auto, files or off, not '$WS_TLS'" ;; esac
address=$(cfg address "")
if [[ "$address" == "auto" ]]; then
    address=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
    [[ -n "$address" ]] || die "config.yml: address: auto, but the public IP address could not be looked up. Fill it in."
fi
if [[ -n "$address" ]]; then
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "config.yml: address must be empty, auto, or an IPv4 address like 20.1.2.3, not '$address'"
    WS_IP="$address"
    WS_HOSTNAME="${address//./-}.sslip.io"
    if [[ "$WS_TLS" == "off" ]]; then
        WS_PUBLIC_URL="http://$WS_HOSTNAME"; [[ "$WS_HTTP_PORT" == 80 ]] || WS_PUBLIC_URL+=":$WS_HTTP_PORT"
    else
        WS_PUBLIC_URL="https://$WS_HOSTNAME"; [[ "$WS_HTTPS_PORT" == 443 ]] || WS_PUBLIC_URL+=":$WS_HTTPS_PORT"
    fi
else
    WS_IP=""; WS_HOSTNAME=""; WS_PUBLIC_URL="http://127.0.0.1:8080"
fi

# ---------------------------------------------------------------- container engine
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    engine=(docker); compose=(docker compose)
    export WS_SOCKET=/var/run/docker.sock
    # Docker runs containers as the real root: setup gives the login cards to you, so you can read and copy them.
    export WS_OWNER="$(id -u):$(id -g)"
elif command -v podman >/dev/null 2>&1; then
    engine=(podman); compose=(podman compose)
    export WS_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ ! -S "$WS_SOCKET" ]]; then
        echo "Starting the podman API socket (ShinyProxy uses it to start containers)."
        systemctl --user start podman.socket
    fi
else
    die "neither Docker nor podman found"
fi

# SELinux (Fedora): label bind mounts so containers may read them.
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    export WS_SELINUX=1 WS_RW=":z" WS_RO=":ro,z"
fi
export WS_HOST_RUN="$PWD/run"
mkdir -p run/data run/state run/caddy
# setup reads the participant list and limits from here (run/ is what its container sees).
if [[ -f config.yml ]]; then cp config.yml run/config.yml; else rm -f run/config.yml; fi

# ---------------------------------------------------------------- Caddy (HTTPS), only with an address
profiles=()
export WS_CERTS="$PWD/run/caddy"          # mounted as /etc/letsencrypt; the real one only with tls: files
write_caddyfile() {
    local site="$WS_HOSTNAME" redirect="$WS_PUBLIC_URL"
    {
        echo "# Written by ./ws from config.yml; do not edit (it is rewritten on every ./ws up)."
        echo "{"
        echo "	http_port $WS_HTTP_PORT"
        echo "	https_port $WS_HTTPS_PORT"
        [[ "$WS_TLS" == "off" ]] && echo "	auto_https off"
        echo "}"
        case "$WS_TLS" in
            off)
                echo "http://$site:$WS_HTTP_PORT, http://$WS_IP:$WS_HTTP_PORT {"
                echo "	encode gzip"
                echo "	reverse_proxy shinyproxy:8080"
                echo "}" ;;
            *)
                echo "$site {"
                [[ "$WS_TLS" == "files" ]] && echo "	tls /etc/letsencrypt/live/$site/fullchain.pem /etc/letsencrypt/live/$site/privkey.pem"
                [[ "$WS_TLS" == "internal" ]] && echo "	tls internal"
                echo "	encode gzip"
                echo "	reverse_proxy shinyproxy:8080"
                echo "}"
                echo "# Someone who types only the IP address is sent to the name the certificate is for."
                echo "http://$WS_IP {"
                echo "	redir $redirect{uri}"
                echo "}" ;;
        esac
    } > run/caddy/Caddyfile
}
if [[ -n "$WS_IP" ]]; then
    profiles=(--profile tls)
    if [[ "$WS_TLS" == "files" ]]; then
        [[ -f "/etc/letsencrypt/live/$WS_HOSTNAME/fullchain.pem" ]] \
            || die "tls: files, but there is no certificate in /etc/letsencrypt/live/$WS_HOSTNAME/"
        export WS_CERTS=/etc/letsencrypt
    fi
    write_caddyfile
fi

cmd="${1:-help}"; shift || true
case "$cmd" in
    build)        "${compose[@]}" build api ;;
    prepare-data) "${compose[@]}" --profile tools run --rm prepare-data ;;
    setup)        before=$(cat run/shinyproxy/application.yml 2>/dev/null | md5sum)
                  "${compose[@]}" --profile tools run --rm setup Rscript /srv/workshop/app/setup.R "$@"
                  # ShinyProxy reads its accounts and settings only at start: restart it if it runs and they changed.
                  # That ends the open sessions: participants reload the page (answers and code are kept).
                  if [[ "$before" != "$(cat run/shinyproxy/application.yml 2>/dev/null | md5sum)" ]] \
                     && [[ -n "$("${engine[@]}" ps -q --filter name=rworkshop-shinyproxy 2>/dev/null)" ]]; then
                      echo "Restarting ShinyProxy to load the new accounts/settings. Participants who have the workshop open"
                      echo "see a message to reload the page; their answers and code are kept."
                      "${compose[@]}" restart shinyproxy >/dev/null
                  fi ;;
    test)         "${compose[@]}" --profile tools run --rm test ;;
    e2e)          "${engine[@]}" build -q --target base -t localhost/rworkshop-base:latest -f server/Dockerfile . >/dev/null
                  "${engine[@]}" build -q -t localhost/rworkshop-e2e:latest -f server/Dockerfile.e2e . >/dev/null
                  "${compose[@]}" --profile tools run --rm e2e ;;
    address)
        echo "Participants open: $WS_PUBLIC_URL"
        if [[ -n "$WS_IP" ]]; then
            echo "  IP address $WS_IP; ports: http $WS_HTTP_PORT, https $WS_HTTPS_PORT; HTTPS: $WS_TLS"
            echo "  typing http://$WS_IP$([[ $WS_HTTP_PORT == 80 ]] || echo ":$WS_HTTP_PORT") redirects there"
        else
            echo "  (no address in config.yml: only on this computer)"
        fi ;;
    up)
        [[ -f run/shinyproxy/application.yml ]] || die "run ./ws setup first"
        [[ -f run/data/synthea-covid19-10k.duckdb ]] || die "no dataset; run ./ws prepare-data first"
        "${compose[@]}" "${profiles[@]}" up -d
        # Caddy reads run/caddy/Caddyfile only at start; restart it so a changed config.yml takes effect.
        [[ -z "$WS_IP" ]] || "${compose[@]}" "${profiles[@]}" restart caddy >/dev/null
        echo "Participants open: $WS_PUBLIC_URL   (login cards: run/handouts/all.html)" ;;
    down)         "${compose[@]}" --profile tls down
                  # Participants' containers are started by ShinyProxy, not compose.
                  ids=$("${engine[@]}" ps -aq --filter label=openanalytics.eu/sp-instance 2>/dev/null || true)
                  [[ -z "$ids" ]] || "${engine[@]}" rm -f $ids >/dev/null ;;
    logs)         "${compose[@]}" "${profiles[@]}" logs -f "$@" ;;
    ps)           "${engine[@]}" ps --filter network=rworkshop ;;
    *)            sed -n "2,12p" "$0" ;;
esac
