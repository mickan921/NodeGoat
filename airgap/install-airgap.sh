#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="initializing"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${NODEGOAT_AIRGAP_LOG_FILE:-$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"
APT_WORK_DIR="$SCRIPT_DIR/.apt-work"
APT_SOURCE_FILE="$APT_WORK_DIR/nodegoat-airgap.sources.list"
APT_LAST_LOG="$LOG_DIR/apt-last.log"

TARGET_UBUNTU="24.04"
TARGET_ARCH="amd64"
WEB_IMAGE="nodegoat-web:1.3.0-airgap"
MONGO_IMAGE="mongo:4.4"
COMPOSE_PROJECT="nodegoat-airgap"
COMPOSE_NETWORK="${COMPOSE_PROJECT}_default"
REQUIRED_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

if [[ "${NODEGOAT_AIRGAP_LOGGING:-0}" != "1" ]]; then
    export NODEGOAT_AIRGAP_LOGGING=1
    export NODEGOAT_AIRGAP_LOG_FILE="$LOG_FILE"
    bash "$0" "$@" 2>&1 | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
fi

on_error() {
    local line="$1"
    local command="$2"
    echo
    echo "ERROR: offline install failed during step: $STEP"
    echo "Line: $line"
    echo "Command: $command"
    echo "Full log: $LOG_FILE"
    echo
    echo "Last 40 log lines:"
    tail -n 40 "$LOG_FILE" || true
    echo
    echo "Run this for a focused report:"
    echo "  sudo ./diagnose-airgap.sh"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

info() {
    echo
    echo "==> $*"
}

fail_with_fix() {
    echo
    echo "ERROR: $1"
    shift || true
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@"
    fi
    echo
    echo "Full log: $LOG_FILE"
    echo "Run sudo ./diagnose-airgap.sh for a focused report."
    exit 1
}

require_root() {
    STEP="checking privileges"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail_with_fix "install-airgap.sh must run as root." "Run: sudo ./install-airgap.sh"
    fi
}

require_platform() {
    STEP="checking target platform"
    if [[ ! -r /etc/os-release ]]; then
        fail_with_fix "/etc/os-release is missing." "This installer supports Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH}."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    local arch
    arch="$(dpkg --print-architecture)"

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "$TARGET_UBUNTU" || "$arch" != "$TARGET_ARCH" ]]; then
        fail_with_fix "unsupported target platform." \
            "Expected: Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH}" \
            "Detected: ${PRETTY_NAME:-unknown} / $arch" \
            "Rebuild the airgap bundle for this exact OS and architecture."
    fi
}

require_bundle_files() {
    STEP="checking bundle contents"
    local missing=()
    local required_files=(
        "$SCRIPT_DIR/SHA256SUMS"
        "$SCRIPT_DIR/compose.airgap.yml"
        "$SCRIPT_DIR/images/nodegoat-images.tar.gz"
        "$SCRIPT_DIR/debs/Packages.gz"
        "$SCRIPT_DIR/install-airgap.sh"
        "$SCRIPT_DIR/diagnose-airgap.sh"
        "$SCRIPT_DIR/reset-db.sh"
    )

    for file in "${required_files[@]}"; do
        [[ -e "$file" ]] || missing+=("${file#$SCRIPT_DIR/}")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'Missing bundle files:\n'
        printf '  %s\n' "${missing[@]}"
        fail_with_fix "the airgap bundle is incomplete." \
            "On the internet-connected builder, rerun:" \
            "  ./airgap/build-bundle.sh" \
            "Then copy the new dist/nodegoat-airgap-ubuntu${TARGET_UBUNTU}-${TARGET_ARCH}.tar.gz to this VM."
    fi
}

verify_checksums() {
    STEP="verifying bundle checksums"
    if ! (
        cd "$SCRIPT_DIR"
        sha256sum -c SHA256SUMS
    ); then
        fail_with_fix "bundle checksum verification failed." \
            "The bundle may be corrupted, partially copied, or edited after extraction." \
            "Recopy nodegoat-airgap-ubuntu${TARGET_UBUNTU}-${TARGET_ARCH}.tar.gz and its .sha256 file from the internet-connected builder."
    fi
}

write_local_apt_source() {
    STEP="configuring local apt source"
    mkdir -p "$APT_WORK_DIR/lists/partial" "$APT_WORK_DIR/archives/partial"
    cat > "$APT_SOURCE_FILE" <<APT
deb [trusted=yes] file:$SCRIPT_DIR/debs ./
APT
}

extract_missing_packages() {
    local log_file="$1"
    {
        grep -Eo 'Depends: [A-Za-z0-9.+:-]+' "$log_file" | awk '{print $2}' || true
        grep -Eo 'PreDepends: [A-Za-z0-9.+:-]+' "$log_file" | awk '{print $2}' || true
        grep -Eo 'Unable to locate package [A-Za-z0-9.+:-]+' "$log_file" | awk '{print $5}' || true
        grep -Eo 'Package [A-Za-z0-9.+:-]+ is not available' "$log_file" | awk '{print $2}' || true
        grep -Eo '[A-Za-z0-9.+:-]+ has no installation candidate' "$log_file" | awk '{print $1}' || true
    } | sort -u | tr '\n' ' '
}

handle_apt_failure() {
    local stage="$1"
    local missing
    missing="$(extract_missing_packages "$APT_LAST_LOG")"

    echo
    echo "ERROR: apt failed while $stage."
    echo "Apt log: $APT_LAST_LOG"
    echo

    if grep -Eiq 'https?://|Temporary failure resolving|Could not resolve|Network is unreachable|Failed to fetch .*://|Connection timed out' "$APT_LAST_LOG"; then
        echo "This offline VM tried to use or resolve an internet source."
        echo "The installer is expected to use only this local bundle."
        echo "Check that you extracted the complete bundle and did not edit the apt source file."
        echo
    fi

    if [[ -n "$missing" ]]; then
        echo "Likely missing package(s):"
        printf '  %s\n' $missing
        echo
        echo "On the internet-connected Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH} builder, run:"
        echo "  ./airgap/build-bundle.sh --include-packages \"$missing\""
    else
        echo "I could not confidently parse a missing package name from apt output."
        echo "Bring the apt log back to the internet-connected builder and rebuild the bundle."
        echo "A safe rebuild command is:"
        echo "  ./airgap/build-bundle.sh"
    fi

    echo
    echo "Then transfer the rebuilt tarball back here, extract it, and rerun:"
    echo "  sudo ./install-airgap.sh"
    exit 1
}

install_docker_packages() {
    STEP="installing Docker packages from local bundle"
    write_local_apt_source

    local apt_options=(
        -o "Dir::Etc::sourcelist=$APT_SOURCE_FILE"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State::lists=$APT_WORK_DIR/lists"
        -o "Dir::Cache::archives=$APT_WORK_DIR/archives"
        -o "APT::Get::List-Cleanup=0"
        -o "Acquire::Retries=0"
        -o "Acquire::Languages=none"
    )

    info "Updating apt from local file repository only"
    : > "$APT_LAST_LOG"
    if ! apt-get "${apt_options[@]}" update 2>&1 | tee "$APT_LAST_LOG"; then
        handle_apt_failure "updating the local apt repository"
    fi

    info "Installing Docker packages from local .deb repository"
    : > "$APT_LAST_LOG"
    if ! apt-get "${apt_options[@]}" install -y --no-install-recommends "${REQUIRED_PACKAGES[@]}" 2>&1 | tee "$APT_LAST_LOG"; then
        handle_apt_failure "installing Docker packages"
    fi
}

start_docker() {
    STEP="starting Docker service"
    info "Starting Docker"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker || {
            systemctl status docker --no-pager || true
            fail_with_fix "Docker service did not start." \
                "Check the service output above." \
                "If a package is missing, rerun the bundle builder with the missing package name."
        }
    else
        service docker start || fail_with_fix "Docker service did not start." "This VM does not have systemctl; inspect service docker status."
    fi
}

load_images() {
    STEP="loading Docker images"
    info "Loading Docker images from bundle"
    docker load -i "$SCRIPT_DIR/images/nodegoat-images.tar.gz"
}

verify_images() {
    STEP="verifying required Docker images"
    local missing=()
    local wrong_arch=()
    local arch
    for image in "$WEB_IMAGE" "$MONGO_IMAGE"; do
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            missing+=("$image")
            continue
        fi

        arch="$(docker image inspect --format '{{.Architecture}}' "$image")"
        if [[ "$arch" != "$TARGET_ARCH" ]]; then
            wrong_arch+=("$image ($arch)")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'Missing Docker image(s):\n'
        printf '  %s\n' "${missing[@]}"
        fail_with_fix "required Docker images are not loaded." \
            "Bring a rebuilt images/nodegoat-images.tar.gz from the internet-connected builder." \
            "Expected image tags: $WEB_IMAGE and $MONGO_IMAGE"
    fi

    if [[ ${#wrong_arch[@]} -gt 0 ]]; then
        printf 'Wrong-architecture Docker image(s):\n'
        printf '  %s\n' "${wrong_arch[@]}"
        fail_with_fix "loaded Docker images do not match ${TARGET_ARCH}." \
            "Rebuild the bundle on an Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH} builder and recopy images/nodegoat-images.tar.gz."
    fi
}

ensure_port_available() {
    STEP="checking port 4000"
    if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :4000 )" | grep -q ':4000'; then
        ss -ltnp "( sport = :4000 )" || true
        fail_with_fix "port 4000 is already in use." \
            "Stop the process using port 4000 or edit compose.airgap.yml to publish a different host port."
    fi
}

seed_database() {
    STEP="resetting and seeding MongoDB"
    info "Resetting and seeding MongoDB for reproducible training data"
    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" up -d --no-build --pull never mongo
    docker run --rm \
        --network "$COMPOSE_NETWORK" \
        -e NODE_ENV=production \
        -e MONGODB_URI=mongodb://mongo:27017/nodegoat \
        "$WEB_IMAGE" \
        sh -c "until nc -z -w 2 mongo 27017 && echo 'mongo is ready for seed data'; do sleep 2; done; node artifacts/db-reset.js"
}

start_nodegoat() {
    STEP="starting NodeGoat Compose stack"
    info "Starting NodeGoat"
    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" up -d --no-build --pull never
}

verify_http() {
    STEP="verifying NodeGoat HTTP response"
    info "Waiting for http://localhost:4000/login"
    local attempts=30
    local i
    for ((i = 1; i <= attempts; i++)); do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsS --max-time 3 http://localhost:4000/login >/dev/null; then
                echo "NodeGoat is responding at http://localhost:4000/login"
                return 0
            fi
        else
            if timeout 3 bash -c '</dev/tcp/127.0.0.1/4000' >/dev/null 2>&1; then
                echo "Port 4000 is open. Install curl if you want HTTP-level verification."
                return 0
            fi
        fi
        sleep 2
    done

    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" ps || true
    docker compose -f "$SCRIPT_DIR/compose.airgap.yml" logs --tail=80 || true
    fail_with_fix "NodeGoat did not answer on http://localhost:4000/login in time." \
        "Run sudo ./diagnose-airgap.sh and inspect the Compose logs above."
}

main() {
    echo "NodeGoat offline installer"
    echo "Log: $LOG_FILE"

    require_root
    require_platform
    require_bundle_files
    verify_checksums
    install_docker_packages
    start_docker
    load_images
    verify_images
    ensure_port_available
    seed_database
    start_nodegoat
    verify_http

    echo
    echo "Install complete."
    echo "Open: http://<VM-IP>:4000/"
    echo "Default users:"
    echo "  admin / Admin_123"
    echo "  user1 / User1_123"
    echo "  user2 / User2_123"
}

main "$@"
