#!/bin/sh
# Installs sqlpen: the newest release of it, or the one SQLPEN_VERSION names, checked against
# that release's SHA256SUMS and put in ~/.local/bin (SQLPEN_INSTALL changes the directory). No
# sudo, and nothing is touched before the file has been checked.
#
#   curl -fsSL https://raw.githubusercontent.com/bateri/sqlpen/main/install.sh | sh
#
# It needs curl, and sha256sum or shasum. A file downloaded with curl is not quarantined by macOS,
# which is why this and not a browser is the way to fetch it (a browser's download is: see the
# README).
#
# This is pencere's installer (bateri/pencere, cli/install.sh) for the command released the same way
# (a file `<binary>-<version>-<target>` and SHA256SUMS on a GitHub release `<prefix><version>`): the
# three lines below, the names of its variables, and that there is no file for an Intel Mac, are
# what is sqlpen's.
set -eu

REPO=bateri/sqlpen
BINARY=sqlpen
TAG_PREFIX=v

# For tests only. A URL (`file://…` is one) that stands in for GitHub: it holds `releases.json`,
# the listing of the repository's releases as the API answers it, and a directory `<tag>/` for each
# release with its files. Nothing else reads it, and a person has no use for it.
BASE=${SQLPEN_DOWNLOAD_BASE:-}

if [ -n "$BASE" ]; then
    FILES=$BASE
    LISTING=$BASE/releases.json
else
    FILES=https://github.com/$REPO/releases/download
    LISTING=https://api.github.com/repos/$REPO/releases?per_page=100
fi

fail() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is needed"

# From where the files come: https only, unless a test points the script at files.
fetch() {
    if [ -n "$BASE" ]; then
        curl -fsSL "$1" -o "$2"
    else
        curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2"
    fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        fail "sha256sum or shasum is needed to check the download"
    fi
}

# ---- which file ----------------------------------------------------------------------------

os=$(uname -s)
cpu=$(uname -m)
case $os in
    Darwin) system=apple-darwin ;;
    Linux) system=unknown-linux-musl ;;
    *) fail "there is no $BINARY for $os: the releases are for macOS and Linux (https://github.com/$REPO/releases)" ;;
esac
case $cpu in
    arm64 | aarch64) arch=aarch64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) fail "there is no $BINARY for a $cpu processor: the releases are for arm64 and x86_64 (https://github.com/$REPO/releases)" ;;
esac
# A shell that runs under Rosetta says x86_64 on an Apple silicon Mac: the executable to install is
# the Mac's own.
if [ "$os" = Darwin ] && [ "$arch" = x86_64 ] &&
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
    arch=aarch64
fi
# bateri, the terminal that shows sqlpen's interface, runs on Apple silicon only.
[ "$os" = Darwin ] && [ "$arch" = x86_64 ] &&
    fail "there is no $BINARY for an Intel Mac: the releases are for Apple silicon Macs and Linux (https://github.com/$REPO/releases)"
target=$arch-$system

# ---- which version -------------------------------------------------------------------------

tmp=$(mktemp -d "${TMPDIR:-/tmp}/$BINARY-install.XXXXXX") || fail "cannot make a temporary directory"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# The newest release of this command that has the file for this machine. A draft and a
# pre-release do not count, nor do tags that are not `<prefix>x.y.z`, and a release without
# `<binary>-<version>-<target>` among its files is not one to install here. The listing is read
# without jq: each release has one `tag_name`, and the `draft`, `prerelease` and file `name`s that
# follow it before the next.
newest() {
    tr ',' '\n' <"$1" | awk -v prefix="$TAG_PREFIX" -v binary="$BINARY" -v target="$target" '
        function flush() {
            if (tag != "" && !draft && !pre && has && version ~ /^[0-9]+\.[0-9]+\.[0-9]+$/)
                print version
        }
        /"tag_name"[ \t]*:[ \t]*"/ {
            flush()
            tag = $0
            sub(/.*"tag_name"[ \t]*:[ \t]*"/, "", tag)
            sub(/".*/, "", tag)
            version = index(tag, prefix) == 1 ? substr(tag, length(prefix) + 1) : ""
            want = binary "-" version "-" target
            draft = 0
            pre = 0
            has = 0
        }
        /"draft"[ \t]*:[ \t]*true/ { draft = 1 }
        /"prerelease"[ \t]*:[ \t]*true/ { pre = 1 }
        /"name"[ \t]*:[ \t]*"/ {
            name = $0
            sub(/.*"name"[ \t]*:[ \t]*"/, "", name)
            sub(/".*/, "", name)
            if (version != "" && name == want) has = 1
        }
        END { flush() }
    ' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

version=${SQLPEN_VERSION:-}
version=${version#v}
if [ -z "$version" ]; then
    fetch "$LISTING" "$tmp/releases.json" ||
        fail "cannot list the releases of $REPO: is there a network, and has GitHub not answered too many times?"
    version=$(newest "$tmp/releases.json")
    [ -n "$version" ] || fail "$REPO has no release of $BINARY for $target yet (https://github.com/$REPO/releases)"
fi
case $version in
    *[!0-9.]* | .* | *.) fail "'$version' is not a version (x.y.z)" ;;
esac

# ---- download, check, install --------------------------------------------------------------

tag=$TAG_PREFIX$version
asset=$BINARY-$version-$target
fetch "$FILES/$tag/$asset" "$tmp/$asset" ||
    fail "cannot download $asset from the release $tag of $REPO: has that release a file for $target?"
fetch "$FILES/$tag/SHA256SUMS" "$tmp/SHA256SUMS" ||
    fail "cannot download SHA256SUMS from the release $tag of $REPO"

want=$(awk -v file="$asset" '{ name = $2; sub(/^\*/, "", name); if (name == file) print $1 }' "$tmp/SHA256SUMS")
# One sum of 64 hexadecimal digits for the file, and no other.
set -- $want
[ $# -eq 1 ] || fail "SHA256SUMS of $tag does not name $asset exactly once; nothing was installed"
case $1 in
    *[!0-9a-f]*) fail "SHA256SUMS of $tag has no sum for $asset; nothing was installed" ;;
esac
[ ${#1} -eq 64 ] || fail "SHA256SUMS of $tag has no sum for $asset; nothing was installed"
got=$(sha256 "$tmp/$asset")
[ "$got" = "$1" ] ||
    fail "$asset is not the file SHA256SUMS of $tag has the sum of ($got, not $1); nothing was installed"

if [ -n "${SQLPEN_INSTALL:-}" ]; then
    dir=$SQLPEN_INSTALL
else
    [ -n "${HOME:-}" ] || fail "HOME is not set; SQLPEN_INSTALL says where to install"
    dir=$HOME/.local/bin
fi
mkdir -p "$dir" || fail "cannot make $dir"
# The file is made beside its place and moved onto it: the rename is atomic, and a program that is
# running the old one keeps it (macOS kills an executable whose file is written over under its
# cached signature).
staged=$dir/.$BINARY.$$
if ! { cp "$tmp/$asset" "$staged" && chmod 755 "$staged" && mv -f "$staged" "$dir/$BINARY"; }; then
    rm -f "$staged"
    fail "cannot install $dir/$BINARY"
fi

printf 'installed %s %s (%s) to %s/%s\n' "$BINARY" "$version" "$target" "$dir" "$BINARY"
case :$PATH: in
    *:"$dir":*) ;;
    *) printf '%s is not on your PATH. Add it with:\n\n    export PATH="%s:$PATH"\n' "$dir" "$dir" ;;
esac
