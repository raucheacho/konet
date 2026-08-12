#!/bin/sh
# Konet CLI installer.
#
#   curl -fsSL https://raw.githubusercontent.com/raucheacho/konet/main/install.sh | sh
#
# Downloads the latest release archive for this platform, verifies it against
# the published checksums file, and installs the `konet` binary.
#
# `konet upgrade` fetches and runs this script, which is why it must stay
# POSIX sh and must not depend on anything outside coreutils + curl/wget.
#
# Refuses to run when Homebrew or Scoop already manages konet: that manager is
# the only thing that should replace its own binary.
#
# Environment:
#   KONET_INSTALL_DIR   where to put the binary (default: ~/.local/bin — never
#                       /usr/local/bin, which on Intel macOS is Homebrew's own
#                       prefix)
#   KONET_VERSION       version to install, e.g. v0.3.0 (default: latest)

set -eu

REPO="raucheacho/konet"
BINARY="konet"

info()  { printf '%s\n' "$*"; }
warn()  { printf '%s\n' "$*" >&2; }
fatal() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ── Fetch helper ────────────────────────────────────────────────────────────
# Fails on a non-2xx status rather than saving the error page, which is the
# whole reason `konet upgrade` used to hand a 404 page to sh.
fetch() {
    _f_url="$1"
    _f_out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_f_url" -o "$_f_out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_f_out" "$_f_url"
    else
        fatal "neither curl nor wget is available"
    fi
}

fetch_stdout() {
    _fs_url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_fs_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$_fs_url"
    else
        fatal "neither curl nor wget is available"
    fi
}

# ── Platform ────────────────────────────────────────────────────────────────
detect_platform() {
    _dp_os="$(uname -s)"
    _dp_arch="$(uname -m)"

    case "$_dp_os" in
        Linux)  _dp_os="linux" ;;
        Darwin) _dp_os="darwin" ;;
        *) fatal "unsupported OS: $_dp_os (Windows users: use Scoop, or download from https://github.com/$REPO/releases/latest)" ;;
    esac

    case "$_dp_arch" in
        x86_64|amd64)  _dp_arch="amd64" ;;
        arm64|aarch64) _dp_arch="arm64" ;;
        *) fatal "unsupported architecture: $_dp_arch" ;;
    esac

    printf '%s_%s' "$_dp_os" "$_dp_arch"
}

# ── Version ─────────────────────────────────────────────────────────────────
latest_version() {
    fetch_stdout "https://api.github.com/repos/$REPO/releases/latest" \
        | tr ',' '\n' \
        | grep '"tag_name"' \
        | head -n 1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# ── Refuse to fight a package manager ───────────────────────────────────────
# Overwriting a brew- or scoop-managed binary leaves that manager's metadata
# describing a file it no longer controls: `brew list --versions` reports one
# version, `konet --version` another, and the next `brew upgrade` silently
# reverts whatever was installed here. The manager that installed it is the only
# thing that should replace it.
refuse_if_managed() {
    if command -v brew >/dev/null 2>&1; then
        if brew list --cask konet >/dev/null 2>&1; then
            fatal "konet is already installed by Homebrew. Upgrade it with:

    brew upgrade --cask konet

Installing over it would leave brew's metadata describing a binary it no longer
controls. Set KONET_INSTALL_DIR to install a second copy elsewhere on purpose."
        fi
    fi

    if command -v scoop >/dev/null 2>&1; then
        if scoop list konet >/dev/null 2>&1; then
            fatal "konet is already installed by Scoop. Upgrade it with:

    scoop update konet"
        fi
    fi
}

# ── Install directory ───────────────────────────────────────────────────────
# Defaults to ~/.local/bin, never /usr/local/bin: on Intel macOS that *is*
# Homebrew's prefix, so the old default collided with brew by construction.
install_dir() {
    if [ -n "${KONET_INSTALL_DIR:-}" ]; then
        printf '%s' "$KONET_INSTALL_DIR"
        return
    fi

    printf '%s/.local/bin' "$HOME"
}

# ── Checksum verification ───────────────────────────────────────────────────
# POSIX sh has no function-local variables, so every name in here is prefixed:
# plain `archive=` would overwrite the caller's, which is exactly the bug that
# made tar look for "$tmp/$tmp/konet_....tar.gz".
verify_checksum() {
    _vc_archive="$1"
    _vc_checksums="$2"
    _vc_name="$(basename "$_vc_archive")"

    _vc_expected="$(grep " $_vc_name\$" "$_vc_checksums" 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "$_vc_expected" ]; then
        warn "warning: $_vc_name is not listed in the checksums file; skipping verification"
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        _vc_actual="$(sha256sum "$_vc_archive" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        _vc_actual="$(shasum -a 256 "$_vc_archive" | awk '{print $1}')"
    else
        warn "warning: no sha256 tool available; skipping verification"
        return 0
    fi

    [ "$_vc_expected" = "$_vc_actual" ] \
        || fatal "checksum mismatch for $_vc_name (expected $_vc_expected, got $_vc_actual)"
    info "✓ checksum verified"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    refuse_if_managed
    platform="$(detect_platform)"

    version="${KONET_VERSION:-}"
    [ -n "$version" ] || version="$(latest_version)"
    [ -n "$version" ] || fatal "could not determine the latest version"

    # Archive names come from .goreleaser.yaml:
    #   {{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}
    bare_version="${version#v}"
    archive="${BINARY}_${bare_version}_${platform}.tar.gz"
    base="https://github.com/$REPO/releases/download/$version"

    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT INT TERM

    info "Installing $BINARY $version ($platform)..."

    fetch "$base/$archive" "$tmp/$archive" \
        || fatal "could not download $base/$archive"

    if fetch "$base/${BINARY}_${bare_version}_checksums.txt" "$tmp/checksums.txt" 2>/dev/null; then
        verify_checksum "$tmp/$archive" "$tmp/checksums.txt"
    else
        warn "warning: checksums file unavailable; skipping verification"
    fi

    tar -xzf "$tmp/$archive" -C "$tmp" || fatal "could not extract $archive"
    [ -f "$tmp/$BINARY" ] || fatal "$BINARY not found in the archive"

    dir="$(install_dir)"
    mkdir -p "$dir"

    if [ -w "$dir" ]; then
        install -m 0755 "$tmp/$BINARY" "$dir/$BINARY" 2>/dev/null \
            || { cp "$tmp/$BINARY" "$dir/$BINARY" && chmod 0755 "$dir/$BINARY"; }
    else
        info "$dir is not writable, using sudo..."
        sudo install -m 0755 "$tmp/$BINARY" "$dir/$BINARY"
    fi

    info "✓ Installed $dir/$BINARY"

    case ":$PATH:" in
        *":$dir:"*) ;;
        *) warn "note: $dir is not on your PATH — add it to your shell profile" ;;
    esac

    "$dir/$BINARY" --version 2>/dev/null || true
}

main "$@"
