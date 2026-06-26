#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="initializing"
WEB_IMAGE="nodegoat-web:1.3.0-airgap"
MONGO_IMAGE="mongo:4.4"
DOCKER_USABLE=0

on_error() {
    local line="$1"
    local command="$2"
    echo
    echo "ERROR: diagnostics failed during step: $STEP"
    echo "Line: $line"
    echo "Command: $command"
    echo "The diagnostic script is read-only; rerun it with sudo if Docker details were unavailable."
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

section() {
    echo
    echo "== $* =="
}

have() {
    command -v "$1" >/dev/null 2>&1
}

main() {
    section "Platform"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "OS: ${PRETTY_NAME:-unknown}"
    else
        echo "OS: /etc/os-release missing"
    fi
    if have dpkg; then
        echo "Architecture: $(dpkg --print-architecture)"
    else
        echo "Architecture: dpkg not found"
    fi

    section "Bundle Files"
    local files=(
        "SHA256SUMS"
        "compose.airgap.yml"
        "images/nodegoat-images.tar.gz"
        "debs/Packages.gz"
        "install-airgap.sh"
        "diagnose-airgap.sh"
        "reset-db.sh"
    )
    local missing_bundle=0
    for file in "${files[@]}"; do
        if [[ -e "$SCRIPT_DIR/$file" ]]; then
            echo "OK: $file"
        else
            echo "MISSING: $file"
            missing_bundle=1
        fi
    done

    section "Commands"
    for command in docker curl sha256sum apt-get systemctl ss; do
        if have "$command"; then
            echo "OK: $command -> $(command -v "$command")"
        else
            echo "MISSING: $command"
        fi
    done

    section "Checksum"
    if [[ -f "$SCRIPT_DIR/SHA256SUMS" ]] && have sha256sum; then
        (cd "$SCRIPT_DIR" && sha256sum -c SHA256SUMS) || true
    else
        echo "Skipped: SHA256SUMS or sha256sum missing"
    fi

    section "Docker Service"
    if have systemctl; then
        systemctl is-enabled docker 2>/dev/null || true
        systemctl is-active docker 2>/dev/null || true
        systemctl status docker --no-pager 2>/dev/null | sed -n '1,20p' || true
    else
        echo "systemctl not available"
    fi

    section "Docker Access"
    if have docker; then
        if docker info >/dev/null 2>&1; then
            DOCKER_USABLE=1
            echo "OK: Docker daemon is reachable by this user."
        else
            echo "FAIL: Docker is installed, but the daemon is not reachable by this user."
            echo "Try: sudo ./diagnose-airgap.sh"
            echo "If that still fails, inspect: sudo systemctl status docker --no-pager"
        fi
    else
        echo "Docker command missing"
    fi

    section "Docker Images"
    if have docker && [[ "$DOCKER_USABLE" -eq 1 ]]; then
        for image in "$WEB_IMAGE" "$MONGO_IMAGE"; do
            if docker image inspect "$image" >/dev/null 2>&1; then
                echo "OK: $image ($(docker image inspect --format '{{.Architecture}}' "$image"))"
            else
                echo "MISSING: $image"
            fi
        done
    elif have docker; then
        echo "Skipped: Docker daemon/access problem must be fixed before image checks are meaningful."
    else
        echo "Docker command missing"
    fi

    section "Compose Status"
    if have docker && [[ "$DOCKER_USABLE" -eq 1 ]] && docker compose version >/dev/null 2>&1; then
        docker compose -f "$SCRIPT_DIR/compose.airgap.yml" ps || true
        echo
        docker compose -f "$SCRIPT_DIR/compose.airgap.yml" logs --tail=60 || true
    elif have docker && [[ "$DOCKER_USABLE" -eq 0 ]]; then
        echo "Skipped: Docker daemon/access problem must be fixed first."
    else
        echo "Docker Compose plugin unavailable"
    fi

    section "Port 4000"
    if have ss; then
        ss -ltnp "( sport = :4000 )" || true
    else
        echo "ss command missing"
    fi

    section "HTTP Check"
    if have curl; then
        curl -fsS --max-time 5 http://localhost:4000/login >/dev/null \
            && echo "OK: http://localhost:4000/login responds" \
            || echo "FAIL: http://localhost:4000/login did not respond"
    else
        echo "curl missing; HTTP check skipped"
    fi

    section "Likely Next Action"
    if [[ "$missing_bundle" -eq 1 ]]; then
        echo "The extracted bundle is incomplete. Rebuild on the internet machine and recopy the tarball."
    elif ! have docker; then
        echo "Docker is not installed. Rerun: sudo ./install-airgap.sh"
    elif [[ "$DOCKER_USABLE" -eq 0 ]]; then
        echo "Docker exists but is not reachable. Start Docker or rerun diagnostics/install with sudo."
    elif ! docker image inspect "$WEB_IMAGE" >/dev/null 2>&1 || ! docker image inspect "$MONGO_IMAGE" >/dev/null 2>&1; then
        echo "Docker images are missing. Bring a rebuilt images/nodegoat-images.tar.gz from the builder and rerun install."
    elif have ss && ss -ltn "( sport = :4000 )" | grep -q ':4000'; then
        echo "Port 4000 is bound. If NodeGoat is not responding, inspect Compose logs above."
    else
        echo "No obvious bundle issue found. Rerun sudo ./install-airgap.sh and review the installer log."
    fi
}

main "$@"
