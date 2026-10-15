#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Alpine/OpenRC, VLESS + REALITY + Vision only. No remote shell snippets are sourced.
set -Eeuo pipefail
umask 077

VERSION=1.14.3
CONF=/etc/vless-chain
BIN=/usr/local/lib/vless-chain/sing-box
INIT=/etc/init.d/vless-chain
BACKUPS=/var/lib/vless-chain-backups
SERVICE=vless-chain
WORK='' LOCKED=0 ACTIVE=0 SNAPSHOT='' CLIENT_PID=''
ROLE='' PUBLIC_HOST='' PUBLIC_PORT='' LISTEN_PORT='' SNI='' EXIT_FILE=''
UUID='' PRIVATE_KEY='' PUBLIC_KEY='' SHORT_ID='' EXIT_IP=''

log() { printf '[vless-chain] %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
usage() {
    cat <<'HELP'
Usage: bash install-vless-chain.sh exit|relay [options]
       bash install-vless-chain.sh status
       bash install-vless-chain.sh rollback BACKUP_ID

  --public-host HOST   This machine's public NAT ingress IPv4/domain (required)
  --public-port PORT   Public TCP port (default: 24443)
  --listen-port PORT   Container TCP port (default: 24443)
  --sni DOMAIN         REALITY handshake target (default: www.cloudflare.com)
  --exit-file PATH     Exit bundle exported on the exit machine (relay only)

Missing settings are prompted through /dev/tty. Alpine + OpenRC, amd64/arm64.
Existing managed installations keep their UUID/key pair/short ID on rerun.
The script manages its own vless-chain service. NAT mappings are set in your panel.
HELP
}
valid_host() {
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || return 1
    [[ $1 != *..* && $1 != *.-* && $1 != *-.* ]] || return 1
    if [[ $1 =~ ^[0-9.]+$ ]]; then
        local a b c d extra
        IFS=. read -r a b c d extra <<< "$1"
        [[ -n $a && -n $b && -n $c && -n $d && -z $extra ]] || return 1
        local octet
        for octet in "$a" "$b" "$c" "$d"; do
            [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
        done
    fi
}
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }
ask() {
    local name=$1 label=$2 fallback=$3 answer
    [[ -n ${!name} ]] && return 0
    [[ -r /dev/tty ]] || die "$label: supply the corresponding command-line option."
    read -r -p "$label${fallback:+ [$fallback]}: " answer </dev/tty
    printf -v "$name" '%s' "${answer:-$fallback}"
}
parse() {
    [[ $# -gt 0 ]] || { usage; exit 0; }
    ROLE=$1; shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --public-host|--public-port|--listen-port|--sni|--exit-file)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value: $1"
                case $1 in
                    --public-host) PUBLIC_HOST=$2;; --public-port) PUBLIC_PORT=$2;;
                    --listen-port) LISTEN_PORT=$2;; --sni) SNI=$2;; --exit-file) EXIT_FILE=$2;;
                esac
                shift 2;;
            *) die "Unknown option: $1";;
        esac
    done
    [[ $ROLE == exit || $ROLE == relay ]] || die 'Role must be exit or relay.'
}
outbound_json() {
    local server=$1 port=$2 uuid=$3 sni=$4 public=$5 sid=$6 tag=${7:-proxy}
    jq -n --arg server "$server" --argjson port "$port" --arg uuid "$uuid" \
        --arg sni "$sni" --arg key "$public" --arg sid "$sid" --arg tag "$tag" '
        {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,
         flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,
         utls:{enabled:true,fingerprint:"chrome"},
         reality:{enabled:true,public_key:$key,short_id:$sid}}}'
}
validate_bundle() {
    local file=$1
    [[ -f $file && ! -L $file ]] || die 'Exit bundle must be a regular file.'
    [[ $(wc -c < "$file") -le 16384 ]] || die 'Exit bundle is too large.'
    jq -e '(.version == 1) and (.exit_ip | type == "string") and
      (.outbound | .type == "vless" and .flow == "xtls-rprx-vision" and
       (.server|type=="string") and (.server_port|type=="number") and
       (.server_port == (.server_port|floor)) and (.server_port>=1 and .server_port<=65535) and
       (.uuid|test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")) and
       .tls.enabled==true and (.tls.server_name|type=="string") and
       .tls.reality.enabled==true and
       (.tls.reality.public_key|test("^[A-Za-z0-9_-]{43}$")) and
       (.tls.reality.short_id|test("^([0-9a-fA-F]{2}){1,8}$")))' "$file" >/dev/null || die 'Invalid exit bundle.'
    local server sni ip
    server=$(jq -r '.outbound.server' "$file"); sni=$(jq -r '.outbound.tls.server_name' "$file")
    ip=$(jq -r '.exit_ip' "$file")
    if ! valid_host "$server" || ! valid_host "$sni" || ! valid_host "$ip"; then die 'Invalid bundle host.'; fi
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Bundle requires the measured IPv4 exit IP.'
    # Reconstruct a small allowlist. Do not inherit detour, TLS bypasses or extra routing options.
    outbound_json "$server" "$(jq -r '.outbound.server_port' "$file")" \
        "$(jq -r '.outbound.uuid' "$file")" "$sni" \
        "$(jq -r '.outbound.tls.reality.public_key' "$file")" \
        "$(jq -r '.outbound.tls.reality.short_id' "$file")" tokyo-exit
}
render_config() {
    local outbound=$1
    jq -n --arg uuid "$UUID" --arg private "$PRIVATE_KEY" --arg sid "$SHORT_ID" \
      --arg sni "$SNI" --argjson port "$LISTEN_PORT" --argjson outbound "$outbound" '
      {log:{level:"warn",timestamp:true},
       dns:{servers:[{type:"local",tag:"local"}]},
       inbounds:[{type:"vless",tag:"vless-in",listen:"0.0.0.0",listen_port:$port,
         users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
         tls:{enabled:true,server_name:$sni,reality:{enabled:true,
           handshake:{server:$sni,server_port:443},private_key:$private,short_id:[$sid]}}}],
       outbounds:[$outbound],route:{default_domain_resolver:"local",
         rules:[{ip_is_private:true,action:"reject"}],final:$outbound.tag}}'
}
service_text() {
    cat <<'OPENRC'
#!/sbin/openrc-run
description="VLESS REALITY chain proxy"
supervisor="supervise-daemon"
command="/usr/local/lib/vless-chain/sing-box"
command_args="run --disable-color -D /var/lib/vless-chain -c /etc/vless-chain/config.json"
command_user="vless-chain:vless-chain"
respawn_delay=3
respawn_max=5
respawn_period=1800
depend() { after net dns; }
start_pre() { "$command" check -c /etc/vless-chain/config.json; }
OPENRC
}
snapshot() {
    local dir had_conf=0 had_bin=0 had_init=0 running=0 enabled=0
    install -d -m 700 "$BACKUPS" || return 1
    dir="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 3)"
    mkdir -m 700 "$dir" || return 1
    if [[ -d $CONF ]]; then cp -a "$CONF" "$dir/config" || return 1; had_conf=1; fi
    # Atomic replacements below keep this hardlink immutable; fall back across filesystems.
    if [[ -f $BIN ]]; then
        ln "$BIN" "$dir/binary" 2>/dev/null || cp -p "$BIN" "$dir/binary" || return 1
        had_bin=1
    fi
    if [[ -f $INIT ]]; then
        cp -p "$INIT" "$dir/service" || return 1; had_init=1
        if rc-service "$SERVICE" status >/dev/null 2>&1; then running=1; fi
    fi
    if [[ -L /etc/runlevels/default/vless-chain ]]; then enabled=1; fi
    printf '%s %s %s %s %s\n' "$had_conf" "$had_bin" "$had_init" "$running" "$enabled" > "$dir/state" || return 1
    printf '%s\n' "$dir"
}
restore_backup() {
    local dir=$1 had_conf had_bin had_init running enabled
    [[ -f $dir/state && ! -L $dir ]] || return 1
    read -r had_conf had_bin had_init running enabled < "$dir/state"
    [[ "$had_conf $had_bin $had_init $running $enabled" =~ ^[01]\ [01]\ [01]\ [01]\ [01]$ ]] || return 1
    if [[ -f $INIT ]]; then rc-service "$SERVICE" stop >/dev/null 2>&1 || true; fi
    [[ $had_conf == 0 || -f $dir/config/managed ]] || return 1
    [[ $had_bin == 0 || -f $dir/binary ]] || return 1
    [[ $had_init == 0 || -f $dir/service ]] || return 1
    rm -f "$CONF/config.json" "$CONF/config.json.next" "$CONF/node.json" "$CONF/vless.txt" "$CONF/exit-outbound.json" "$CONF/managed" "$BIN.next" || return 1
    if [[ $had_conf == 1 ]]; then
        mkdir -p "$CONF"; cp -a "$dir/config/." "$CONF/" || return 1
        chown root:vless-chain "$CONF"; chmod 750 "$CONF"
    else
        rmdir "$CONF" 2>/dev/null || true
    fi
    if [[ $had_bin == 1 ]]; then
        cp -p "$dir/binary" "$BIN.next" && mv -f "$BIN.next" "$BIN" || return 1
    else rm -f "$BIN"; fi
    if [[ $had_init == 1 ]]; then cp -p "$dir/service" "$INIT" || return 1; else rm -f "$INIT"; fi
    if [[ $enabled == 1 ]]; then rc-update add "$SERVICE" default >/dev/null || return 1
    else rc-update del "$SERVICE" default >/dev/null 2>&1 || true; fi
    if [[ $running == 1 ]]; then rc-service "$SERVICE" start || return 1; fi
    return 0
}
cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $CLIENT_PID ]]; then kill "$CLIENT_PID" 2>/dev/null; wait "$CLIENT_PID" 2>/dev/null; fi
    if [[ $ACTIVE == 1 ]]; then
        log "Deployment failed; restoring $SNAPSHOT"
        restore_backup "$SNAPSHOT" || log "Restore failed. Inspect backup: $SNAPSHOT"
    fi
    if [[ $WORK == /tmp/vless-chain.* && -d $WORK && ! -L $WORK ]]; then rm -rf -- "$WORK"; fi
    if [[ $LOCKED == 1 ]]; then rmdir /run/lock/vless-chain.lock; fi
    exit "$result"
}
download_binary() {
    local arch hash archive
    case $(uname -m) in
        x86_64|amd64) arch=amd64; hash=41fc81fd041134d4d7d850a928d7d2cde17a7d6563953f406b22d32a68bfab1f;;
        aarch64|arm64) arch=arm64; hash=12d6d67a4edf0dd54590865b1f4f79cd09ae043a02d648e9d1b5fccc8446ee07;;
        *) die 'Supported architectures: amd64 and arm64.';;
    esac
    archive="sing-box-$VERSION-linux-$arch-musl"
    log "Downloading official sing-box $VERSION ($arch musl)"
    curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 180 \
        "https://github.com/SagerNet/sing-box/releases/download/v$VERSION/$archive.tar.gz" -o "$WORK/core.tar.gz"
    printf '%s  %s\n' "$hash" "$WORK/core.tar.gz" | sha256sum -c - >&2
    tar -xzf "$WORK/core.tar.gz" -C "$WORK" "$archive/sing-box"
    mv "$WORK/$archive/sing-box" "$WORK/sing-box"
    rm -f "$WORK/core.tar.gz"
    chmod 755 "$WORK/sing-box"
    "$WORK/sing-box" version >&2
}
health_test() {
    local port out client_config ip
    for _ in {1..20}; do
        port=$((30000 + $(od -An -N2 -tu2 /dev/urandom) % 30000))
        [[ -z $(ss -H -lnt "sport = :$port") ]] && break
    done
    [[ -z $(ss -H -lnt "sport = :$port") ]] || die 'No temporary local port available.'
    out=$(outbound_json 127.0.0.1 "$LISTEN_PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID")
    client_config="$WORK/client.json"
    jq -n --argjson port "$port" --argjson outbound "$out" '
      {log:{level:"warn"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],
       outbounds:[$outbound],route:{final:"proxy"}}' > "$client_config"
    "$BIN" run --disable-color -c "$client_config" > "$WORK/client.log" 2>&1 &
    CLIENT_PID=$!
    ip=''
    for _ in {1..5}; do
        sleep 1
        kill -0 "$CLIENT_PID" 2>/dev/null || break
        # An empty --noproxy is essential: '*' would silently bypass the proxy.
        if ip=$(curl -4fsS --noproxy '' --proxy "socks5h://127.0.0.1:$port" \
            --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null); then break; fi
    done
    kill "$CLIENT_PID" 2>/dev/null || true; wait "$CLIENT_PID" 2>/dev/null || true; CLIENT_PID=''
    if ! valid_host "$ip" || [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die 'VLESS REALITY health test failed; installation will roll back.'
    fi
    if [[ $ROLE == relay && $ip != "$EXIT_IP" ]]; then die "Unexpected exit IP: $ip (expected $EXIT_IP)."; fi
    EXIT_IP=$ip
    log "Authenticated proxy test passed; measured exit IPv4: $EXIT_IP"
}
export_node() {
    local out
    jq -n --arg role "$ROLE" --arg host "$PUBLIC_HOST" --argjson public_port "$PUBLIC_PORT" \
      --argjson listen_port "$LISTEN_PORT" --arg sni "$SNI" --arg uuid "$UUID" --arg public "$PUBLIC_KEY" \
      --arg sid "$SHORT_ID" '{role:$role,host:$host,public_port:$public_port,listen_port:$listen_port,
       sni:$sni,uuid:$uuid,public_key:$public,short_id:$sid}' > "$CONF/node.json"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#VLESS-%s\n' \
      "$UUID" "$PUBLIC_HOST" "$PUBLIC_PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$ROLE" > "$CONF/vless.txt"
    if [[ $ROLE == exit ]]; then
        out=$(outbound_json "$PUBLIC_HOST" "$PUBLIC_PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" tokyo-exit)
        jq -n --argjson out "$out" --arg ip "$EXIT_IP" '{version:1,outbound:$out,exit_ip:$ip}' > "$CONF/exit-outbound.json"
        chmod 600 "$CONF/exit-outbound.json"
    else rm -f "$CONF/exit-outbound.json"; fi
    chmod 600 "$CONF/node.json" "$CONF/vless.txt"
    chown root:root "$CONF/node.json" "$CONF/vless.txt"
}
main() {
    case ${1:---help} in -h|--help|help) usage; return;; esac
    [[ $(id -u) == 0 ]] || die 'Run as root.'
    if [[ ! -f /etc/alpine-release ]] || ! command -v rc-service >/dev/null; then die 'Requires Alpine Linux with OpenRC.'; fi
    if [[ ${1:-} == status ]]; then
        rc-service "$SERVICE" status
        [[ ! -f $CONF/vless.txt ]] || log "Node URI: $CONF/vless.txt (root only)"
        return
    fi
    install -d -m 755 /run/lock
    mkdir /run/lock/vless-chain.lock 2>/dev/null || die 'Another installer is running, or its lock requires inspection.'
    LOCKED=1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ ${1:-} == rollback ]]; then
        [[ $# == 2 && $2 =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]] || die 'Supply a valid backup ID.'
        [[ -f $BACKUPS/$2/state && ! -L $BACKUPS/$2 ]] || die 'Backup not found.'
        SNAPSHOT=$(snapshot); ACTIVE=1
        restore_backup "$BACKUPS/$2" || die 'Rollback failed.'
        ACTIVE=0; log "Rollback complete. Previous state saved at $SNAPSHOT"; return
    fi
    parse "$@"
    if [[ -e $CONF || -e $BIN || -e $INIT ]]; then
        [[ -f $CONF/managed && ! -L $CONF && ! -L $BIN && ! -L $INIT ]] || die 'Unmanaged files exist at vless-chain paths; inspect before proceeding.'
    fi
    apk add --no-cache bash curl ca-certificates openssl jq openrc iproute2
    local old_host='' old_public=24443 old_listen=24443 old_sni=www.cloudflare.com
    if [[ -f $CONF/node.json ]]; then
        old_host=$(jq -r '.host' "$CONF/node.json"); old_public=$(jq -r '.public_port' "$CONF/node.json")
        old_listen=$(jq -r '.listen_port' "$CONF/node.json"); old_sni=$(jq -r '.sni' "$CONF/node.json")
    fi
    ask PUBLIC_HOST 'This machine public NAT IPv4/domain' "$old_host"
    ask PUBLIC_PORT 'Public TCP port' "$old_public"
    ask LISTEN_PORT 'Container listen TCP port' "$old_listen"
    ask SNI 'REALITY handshake SNI' "$old_sni"
    if ! valid_host "$PUBLIC_HOST" || ! valid_host "$SNI"; then die 'Invalid public host or SNI.'; fi
    [[ $SNI == *.* && ! $SNI =~ ^[0-9.]+$ ]] || die 'SNI must be a DNS name.'
    if ! valid_port "$PUBLIC_PORT" || ! valid_port "$LISTEN_PORT"; then die 'Ports must be integers from 1 to 65535.'; fi
    [[ $LISTEN_PORT -gt 20000 && $PUBLIC_PORT -gt 20000 ]] || die 'Choose NAT proxy ports above 20000.'
    if [[ -n $(ss -H -lnt "sport = :$LISTEN_PORT") ]]; then
        if [[ -f $CONF/managed && -f $CONF/config.json ]] &&
          [[ $(jq -r '.inbounds[0].listen_port' "$CONF/config.json") == "$LISTEN_PORT" ]] &&
          rc-service "$SERVICE" status >/dev/null 2>&1; then :
        else die "TCP $LISTEN_PORT is already in use. Choose a free mapped port."; fi
    fi
    WORK=$(mktemp -d /tmp/vless-chain.XXXXXX)
    local out keys
    if [[ $ROLE == relay ]]; then
        ask EXIT_FILE 'Absolute path to exit-outbound.json' ''
        [[ $EXIT_FILE == /* ]] || die 'Exit bundle path must be absolute.'
        out=$(validate_bundle "$EXIT_FILE"); EXIT_IP=$(jq -r '.exit_ip' "$EXIT_FILE")
    else out='{"type":"direct","tag":"direct"}'; fi
    log "Verifying TLS 1.3 reachability for $SNI (full REALITY test follows)"
    timeout 15 openssl s_client -connect "$SNI:443" -servername "$SNI" -tls1_3 \
      -verify_hostname "$SNI" -verify_return_error -brief </dev/null > "$WORK/tls.log" 2>&1 || die 'SNI TLS 1.3/certificate check failed.'
    download_binary
    if [[ -f $CONF/managed ]]; then
        UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF/config.json")
        PRIVATE_KEY=$(jq -r '.inbounds[0].tls.reality.private_key' "$CONF/config.json")
        SHORT_ID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF/config.json")
        PUBLIC_KEY=$(jq -r '.public_key' "$CONF/node.json")
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
        keys=$("$WORK/sing-box" generate reality-keypair)
        PRIVATE_KEY=$(awk '/^PrivateKey:/{print $2}' <<< "$keys")
        PUBLIC_KEY=$(awk '/^PublicKey:/{print $2}' <<< "$keys")
        SHORT_ID=$(openssl rand -hex 8)
    fi
    [[ $PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Invalid REALITY keys.'
    render_config "$out" > "$WORK/config.json"
    "$WORK/sing-box" check -c "$WORK/config.json"
    SNAPSHOT=$(snapshot); ACTIVE=1
    if [[ -f $INIT ]]; then rc-service "$SERVICE" stop >/dev/null 2>&1 || true; fi
    getent group vless-chain >/dev/null || addgroup -S vless-chain
    id vless-chain >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin -G vless-chain vless-chain
    install -d -m 755 /usr/local/lib/vless-chain
    install -d -m 750 -o root -g vless-chain "$CONF"
    install -d -m 700 -o vless-chain -g vless-chain /var/lib/vless-chain
    install -m 755 "$WORK/sing-box" "$BIN.next"
    mv -f "$BIN.next" "$BIN"
    install -m 640 -o root -g vless-chain "$WORK/config.json" "$CONF/config.json.next"
    mv -f "$CONF/config.json.next" "$CONF/config.json"
    printf 'vless-chain\n' > "$CONF/managed"
    service_text > "$INIT"; chmod 755 "$INIT"
    rc-service "$SERVICE" start
    health_test
    rc-service "$SERVICE" status
    export_node
    rc-update add "$SERVICE" default
    ACTIVE=0
    log "Installed $ROLE; backup: $SNAPSHOT"
    log "Map public TCP $PUBLIC_PORT to container TCP $LISTEN_PORT in your NAT panel."
    log 'This local test does not verify your public NAT mapping. Test from another machine.'
    [[ $ROLE != exit ]] || log "Copy exit bundle securely to relay: $CONF/exit-outbound.json"
    log "Node URI saved at $CONF/vless.txt (contains access credentials):"
    cat "$CONF/vless.txt"
}

# Sourceable for configuration and rollback tests; sourcing never installs anything.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
