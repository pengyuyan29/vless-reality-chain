#!/usr/bin/env bash
set -Eeuo pipefail
ALPINE_VERSION=${ALPINE_VERSION:-3.24}
suffix="vless-test-${ALPINE_VERSION//./-}-$$"
network=$suffix
exit_name="$suffix-exit"
relay_name="$suffix-relay"
tmp=$(mktemp -d)
cleanup() {
    docker rm -f "$exit_name" "$relay_name" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    [[ $tmp == /tmp/* && -d $tmp ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
docker network create "$network" >/dev/null
for name in "$exit_name" "$relay_name"; do
    docker run -d --name "$name" --network "$network" \
      -v "$PWD/install-vless-chain.sh:/install.sh:ro" "alpine:$ALPINE_VERSION" sh -c '
        apk add --no-cache bash curl ca-certificates openrc >/tmp/bootstrap.log 2>&1 || exit 1
        mkdir -p /run/openrc; touch /run/openrc/softlevel /tmp/ready
        exec tail -f /dev/null' >/dev/null
    for _ in {1..60}; do
        docker exec "$name" test -f /tmp/ready && break
        sleep 2
    done
    docker exec "$name" test -f /tmp/ready
done
docker exec "$exit_name" bash /install.sh exit --public-host "$exit_name" \
  --public-port 24443 --listen-port 24443 --sni www.cloudflare.com >/dev/null
docker cp "$exit_name:/etc/vless-chain/exit-outbound.json" "$tmp/bundle.json"
docker cp "$tmp/bundle.json" "$relay_name:/root/bundle.json"
relay_install=(bash /install.sh relay --public-host "$relay_name" --public-port 24443 \
  --listen-port 24443 --sni www.cloudflare.com --exit-file /root/bundle.json)
docker exec "$relay_name" "${relay_install[@]}" >/dev/null
before=$(docker exec "$relay_name" sha256sum /etc/vless-chain/config.json)
docker exec "$relay_name" "${relay_install[@]}" >/dev/null
after=$(docker exec "$relay_name" sha256sum /etc/vless-chain/config.json)
[[ $before == "$after" ]]
# A wrong expected exit must fail its health check and restore the active config.
jq '.exit_ip="203.0.113.99"' "$tmp/bundle.json" > "$tmp/bad.json"
docker cp "$tmp/bad.json" "$relay_name:/root/bundle.json"
if docker exec "$relay_name" "${relay_install[@]}" >/dev/null 2>&1; then
    echo 'Installer accepted the wrong exit IP' >&2; exit 1
fi
[[ $(docker exec "$relay_name" sha256sum /etc/vless-chain/config.json) == "$before" ]]
docker exec "$relay_name" rc-service vless-chain status
docker cp "$tmp/bundle.json" "$relay_name:/root/bundle.json"
check_relay() {
    docker exec "$relay_name" bash -c '
    source /install.sh
    WORK=$(mktemp -d /tmp/vless-chain.XXXXXX); trap cleanup EXIT
    ROLE=relay; LISTEN_PORT=24443
    UUID=$(jq -r .uuid /etc/vless-chain/node.json)
    SNI=$(jq -r .sni /etc/vless-chain/node.json)
    PUBLIC_KEY=$(jq -r .public_key /etc/vless-chain/node.json)
    SHORT_ID=$(jq -r .short_id /etc/vless-chain/node.json)
    EXIT_IP=$(jq -r .exit_ip /root/bundle.json)
    health_test'
}
check_relay >/dev/null
docker exec "$exit_name" rc-service vless-chain stop
# The identical check must now fail, and pass again after restoration.
if check_relay >/dev/null 2>&1; then
    echo 'Relay leaked traffic during exit outage' >&2; exit 1
fi
docker exec "$exit_name" rc-service vless-chain start
check_relay >/dev/null
echo "Alpine $ALPINE_VERSION: installation, key reuse, automatic rollback and no fallback passed."
