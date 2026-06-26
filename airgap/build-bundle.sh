#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STEP="initializing"
TARGET_UBUNTU="24.04"
TARGET_ARCH="amd64"
APP_VERSION="$(grep -m1 '"version"' "$REPO_ROOT/package.json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
WEB_IMAGE="nodegoat-web:${APP_VERSION}-airgap"
MONGO_IMAGE="mongo:4.4"
BUNDLE_NAME="nodegoat-airgap-ubuntu${TARGET_UBUNTU}-${TARGET_ARCH}"
DIST_DIR="$REPO_ROOT/dist"
STAGING_DIR="$DIST_DIR/.airgap-staging"
BUNDLE_DIR="$STAGING_DIR/$BUNDLE_NAME"
DEB_DIR="$BUNDLE_DIR/debs"
IMAGE_DIR="$BUNDLE_DIR/images"
DOC_DIR="$BUNDLE_DIR/docs"
SOURCE_DIR="$BUNDLE_DIR/source"
EXTRA_PACKAGES=()

DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

usage() {
    cat <<USAGE
Usage: ./airgap/build-bundle.sh [--include-packages "pkg1 pkg2"] [--help]

Builds dist/${BUNDLE_NAME}.tar.gz for an offline Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH} VM.

Options:
  --include-packages "..."   Add extra apt packages to the recursive offline .deb bundle.
  --help                     Show this help.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${NODEGOAT_AIRGAP_LOG_FILE:-$LOG_DIR/build-bundle-$(date +%Y%m%d-%H%M%S).log}"
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
    echo "ERROR: build bundle failed during step: $STEP"
    echo "Line: $line"
    echo "Command: $command"
    echo "Full log: $LOG_FILE"
    echo
    echo "Common fixes:"
    echo "- Run this on an internet-connected Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH} machine."
    echo "- Make sure Docker Engine is installed and running."
    echo "- Make sure Docker's official apt repository is configured so docker-ce is visible to apt."
    echo "- If the offline installer reported missing packages, rerun with:"
    echo "  ./airgap/build-bundle.sh --include-packages \"<missing package names>\""
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-packages)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --include-packages requires a quoted package list."
                exit 2
            fi
            read -r -a EXTRA_PACKAGES <<< "$1"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

require_command() {
    local command="$1"
    local hint="$2"
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command"
        echo "$hint"
        exit 1
    fi
}

require_builder_platform() {
    STEP="checking builder platform"
    if [[ ! -r /etc/os-release ]]; then
        echo "ERROR: /etc/os-release is missing. Build this bundle on Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH}."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    local arch
    arch="$(dpkg --print-architecture)"

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "$TARGET_UBUNTU" || "$arch" != "$TARGET_ARCH" ]]; then
        echo "ERROR: This bundle must be built on Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH}."
        echo "Detected: ${PRETTY_NAME:-unknown} / $arch"
        echo "Use a matching internet-connected VM so apt resolves the same packages the airgapped VM needs."
        exit 1
    fi
}

require_docker_apt_repo() {
    STEP="checking Docker apt repository"
    if ! apt-cache policy docker-ce | grep -q 'Candidate:' || apt-cache policy docker-ce | grep -q 'Candidate: (none)'; then
        echo "ERROR: docker-ce is not available through apt on this builder."
        echo
        echo "On the internet-connected builder, configure Docker's Ubuntu apt repository, then rerun this script."
        echo "Reference package set needed for the offline VM:"
        printf '  %s\n' "${DOCKER_PACKAGES[@]}"
        exit 1
    fi
}

collect_recursive_package_names() {
    STEP="resolving recursive apt dependencies"
    local requested=("${DOCKER_PACKAGES[@]}" "${EXTRA_PACKAGES[@]}")
    printf '%s\n' "${requested[@]}"
    apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances "${requested[@]}" \
        | awk '
            /^[A-Za-z0-9][A-Za-z0-9+_.:-]*$/ { print $1 }
            /^[[:space:]]*(PreDepends|Depends):[[:space:]]+[A-Za-z0-9][A-Za-z0-9+_.:-]*/ { print $2 }
        ' \
        | sed '/^</d' \
        | sort -u
}

download_debs() {
    STEP="downloading recursive .deb packages"
    mkdir -p "$DEB_DIR"

    local package_list="$BUNDLE_DIR/package-list.txt"
    collect_recursive_package_names > "$package_list"

    echo "Downloading apt packages listed in $package_list"
    local count
    count="$(wc -l < "$package_list" | tr -d ' ')"
    echo "Package count: $count"

    if [[ "$count" -eq 0 ]]; then
        echo "ERROR: apt dependency resolver returned no packages."
        exit 1
    fi

    mapfile -t packages < "$package_list"
    (
        cd "$DEB_DIR"
        apt-get download "${packages[@]}"
    )

    STEP="creating local apt repository metadata"
    (
        cd "$DEB_DIR"
        dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
        gzip -dc Packages.gz | grep -q '^Package: '
    )
}

build_images() {
    STEP="building NodeGoat image"
    docker build --platform "linux/$TARGET_ARCH" -t "$WEB_IMAGE" "$REPO_ROOT"

    STEP="pulling Mongo image"
    docker pull --platform "linux/$TARGET_ARCH" "$MONGO_IMAGE"

    STEP="verifying image architecture"
    local image
    local arch
    for image in "$WEB_IMAGE" "$MONGO_IMAGE"; do
        arch="$(docker image inspect --format '{{.Architecture}}' "$image")"
        if [[ "$arch" != "$TARGET_ARCH" ]]; then
            echo "ERROR: image $image has architecture $arch, expected $TARGET_ARCH."
            echo "Rebuild on Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH} or check Docker platform settings."
            exit 1
        fi
    done

    STEP="saving Docker images"
    mkdir -p "$IMAGE_DIR"
    docker save "$WEB_IMAGE" "$MONGO_IMAGE" | gzip -c > "$IMAGE_DIR/nodegoat-images.tar.gz"
}

copy_runtime_files() {
    STEP="copying runtime files"
    mkdir -p "$DOC_DIR" "$SOURCE_DIR"

    cp "$SCRIPT_DIR/install-airgap.sh" "$BUNDLE_DIR/install-airgap.sh"
    cp "$SCRIPT_DIR/diagnose-airgap.sh" "$BUNDLE_DIR/diagnose-airgap.sh"
    cp "$SCRIPT_DIR/reset-db.sh" "$BUNDLE_DIR/reset-db.sh"
    cp "$SCRIPT_DIR/compose.airgap.yml" "$BUNDLE_DIR/compose.airgap.yml"
    cp "$REPO_ROOT/AIRGAP_SETUP_GUIDE.md" "$DOC_DIR/AIRGAP_SETUP_GUIDE.md"
    chmod +x "$BUNDLE_DIR/install-airgap.sh" "$BUNDLE_DIR/diagnose-airgap.sh" "$BUNDLE_DIR/reset-db.sh"

    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$REPO_ROOT" archive --format=tar.gz --output="$SOURCE_DIR/nodegoat-source.tar.gz" HEAD
        git -C "$REPO_ROOT" rev-parse HEAD > "$BUNDLE_DIR/source-commit.txt"
        git -C "$REPO_ROOT" status --short > "$BUNDLE_DIR/source-status.txt"
    fi

    cat > "$BUNDLE_DIR/MANIFEST.txt" <<MANIFEST
NodeGoat airgap bundle
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Target OS: Ubuntu ${TARGET_UBUNTU} ${TARGET_ARCH}
Web image: ${WEB_IMAGE}
Mongo image: ${MONGO_IMAGE}
Database behavior: reset/seed on deploy

Top-level commands on offline VM:
  sudo ./install-airgap.sh
  sudo ./diagnose-airgap.sh
  sudo ./reset-db.sh
MANIFEST
}

write_checksums() {
    STEP="writing checksums"
    (
        cd "$BUNDLE_DIR"
        find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    )
}

package_bundle() {
    STEP="packaging final tarball"
    local final_tar="$DIST_DIR/${BUNDLE_NAME}.tar.gz"
    local final_sha="$final_tar.sha256"

    (
        cd "$STAGING_DIR"
        tar -czf "$final_tar" "$BUNDLE_NAME"
    )
    (
        cd "$DIST_DIR"
        sha256sum "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256"
    )

    echo
    echo "Bundle created:"
    echo "  $final_tar"
    echo "  $final_sha"
    echo
    echo "Transfer both files to the airgapped VM."
}

main() {
    echo "NodeGoat airgap bundle builder"
    echo "Log: $LOG_FILE"

    require_builder_platform
    require_command docker "Install Docker Engine on the builder and make sure your user can run docker."
    require_command apt-get "apt-get is required on the Ubuntu builder."
    require_command apt-cache "apt-cache is required on the Ubuntu builder."
    require_command dpkg-scanpackages "Install dpkg-dev on the builder: sudo apt-get install dpkg-dev"
    require_command sha256sum "coreutils is required on the builder."
    require_command gzip "gzip is required on the builder."
    require_command tar "tar is required on the builder."
    require_docker_apt_repo

    STEP="preparing staging directory"
    rm -rf "$STAGING_DIR"
    mkdir -p "$BUNDLE_DIR"

    download_debs
    build_images
    copy_runtime_files
    write_checksums
    package_bundle
}

main "$@"
