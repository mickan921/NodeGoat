#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="initializing"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${NODEGOAT_AIRGAP_LOG_FILE:-$LOG_DIR/reset-db-$(date +%Y%m%d-%H%M%S).log}"
if [[ "${NODEGOAT_AIRGAP_LOGGING:-0}" != "1" ]]; then
    export NODEGOAT_AIRGAP_LOGGING=1
    export NODEGOAT_AIRGAP_LOG_FILE="$LOG_FILE"
    bash "$0" "$@" 2>&1 | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
fi
WEB_IMAGE="nodegoat-web:1.3.0-airgap"
COMPOSE_PROJECT="nodegoat-airgap"
COMPOSE_NETWORK="${COMPOSE_PROJECT}_default"

on_error() {
    local line="$1"
    local command="$2"
    echo
    echo "ERROR: database reset failed during step: $STEP"
    echo "Line: $line"
    echo "Command: $command"
    echo "Full log: $LOG_FILE"
    echo "Run sudo ./diagnose-airgap.sh for a focused report."
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

fail() {
    echo "ERROR: $1"
    echo "Full log: $LOG_FILE"
    exit 1
}

wait_for_http() {
    STEP="waiting for NodeGoat HTTP response"
    local i
    for ((i = 1; i <= 30; i++)); do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsS --max-time 3 http://localhost:4000/login >/dev/null; then
                echo "NodeGoat is responding at http://localhost:4000/login"
                return 0
            fi
        elif timeout 3 bash -c '</dev/tcp/127.0.0.1/4000' >/dev/null 2>&1; then
            echo "Port 4000 is open."
            return 0
        fi
        sleep 2
    done
    return 1
}

seed_database() {
    STEP="seeding MongoDB"
    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" up -d --no-build --pull never mongo
    docker run --rm \
        --network "$COMPOSE_NETWORK" \
        -e NODE_ENV=production \
        -e MONGODB_URI=mongodb://mongo:27017/nodegoat \
        "$WEB_IMAGE" \
        sh -c "until nc -z -w 2 mongo 27017 && echo 'mongo is ready for seed data'; do sleep 2; done; node artifacts/db-reset.js"
}

main() {
    echo "NodeGoat database reset"
    echo "Log: $LOG_FILE"

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "reset-db.sh must run as root. Use: sudo ./reset-db.sh"
    fi

    command -v docker >/dev/null 2>&1 || fail "docker command not found. Run sudo ./install-airgap.sh first."
    docker compose version >/dev/null 2>&1 || fail "docker compose plugin not found. Run sudo ./install-airgap.sh first."
    [[ -f "$SCRIPT_DIR/compose.airgap.yml" ]] || fail "compose.airgap.yml missing from this bundle."

    STEP="stopping stack and removing Mongo volume"
    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" down --volumes --remove-orphans

    seed_database

    STEP="starting web stack"
    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" up -d --no-build --pull never

    if ! wait_for_http; then
        docker compose -f "$SCRIPT_DIR/compose.airgap.yml" logs --tail=80 || true
        fail "NodeGoat did not respond after reset."
    fi

    echo
    echo "Database reset complete."
    echo "Seeded users:"
    echo "  admin / Admin_123"
    echo "  user1 / User1_123"
    echo "  user2 / User2_123"
}

main "$@"
