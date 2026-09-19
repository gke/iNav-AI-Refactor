#!/usr/bin/env bash
#
# create_iNavgke_svn_repo.sh
#
# Creates the SVN repository for the iNavgke (iNAV 9) source tree and imports
# the working source into a standard trunk/branches/tags layout.
#
# Why this exists: the development Flatpak sandbox has no `svn`/`svnadmin` and
# no RabbitSVN. Run this on the host, where subversion is installed.
#
# Usage:
#   ./create_iNavgke_svn_repo.sh                # create repo + layout + import source
#   ./create_iNavgke_svn_repo.sh --no-import    # create repo + layout only
#   ./create_iNavgke_svn_repo.sh --force        # reuse an existing repo dir
#
set -euo pipefail

REPO_NAME="iNavgke"

SRC_PATH="$HOME/Documents/Flight/Code/$REPO_NAME"
SVN_PATH="$HOME/Documents/Flight/SVN/$REPO_NAME"
REPO_URL="file://$SVN_PATH"

DO_IMPORT=1
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --no-import) DO_IMPORT=0 ;;
        --force)     FORCE=1 ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

for bin in svnadmin svn; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "ERROR: '$bin' not found. Install subversion first (e.g. apt/dnf install subversion)." >&2
        exit 1
    }
done

if [ -e "$SVN_PATH" ]; then
    if [ -n "$(ls -A "$SVN_PATH" 2>/dev/null)" ]; then
        if [ "$FORCE" -eq 0 ]; then
            echo "ERROR: $SVN_PATH already exists (non-empty). Use --force to reuse it." >&2
            exit 1
        fi
        echo "Reusing existing repository at $SVN_PATH (--force)."
    else
        rmdir "$SVN_PATH"
    fi
fi

if [ ! -d "$SVN_PATH" ]; then
    echo "Creating repository: $SVN_PATH"
    svnadmin create --fs-type fsfs "$SVN_PATH"
fi

for dir in trunk branches tags; do
    svn ls "$REPO_URL/$dir" >/dev/null 2>&1 || \
        svn mkdir -m "Create standard repository layout" "$REPO_URL/$dir"
done

if [ "$DO_IMPORT" -ne 0 ]; then
    if [ ! -f "$SRC_PATH/src/main/build/version.h" ]; then
        echo "ERROR: iNAV source not found at $SRC_PATH" >&2
        exit 1
    fi

    if svn ls "$REPO_URL/trunk" >/dev/null 2>&1 && [ -n "$(svn ls "$REPO_URL/trunk")" ]; then
        echo "trunk already has content; import skipped."
    else
        REV=""
        if [ -d "$SRC_PATH/.git" ]; then
            REV=" (git $(git -C "$SRC_PATH" describe --tags 2>/dev/null || git -C "$SRC_PATH" rev-parse --short HEAD 2>/dev/null))"
        fi

        STAGE=$(mktemp -d)
        trap 'rm -rf "$STAGE"' EXIT

        echo "Staging source without git metadata ..."
        ( cd "$SRC_PATH" && tar --exclude='.git' -cf - . ) | ( cd "$STAGE" && tar -xf - )

        echo "Importing iNAV source into trunk/ ..."
        svn import "$STAGE" "$REPO_URL/trunk" -m "Import iNAV 9 source$REV"
    fi

    WC=$(mktemp -d)
    svn checkout --depth empty "$REPO_URL" "$WC"
    svn propset svn:global-ignores "obj build *.log" "$WC"
    svn commit -m "Set svn:global-ignores for build artifacts" "$WC"
    rm -rf "$WC"
fi

echo
echo "Done."
echo "Repo    : $REPO_URL"
echo "Checkout example:"
echo "  svn checkout $REPO_URL/trunk \$HOME/Documents/Flight/OtherCode/iNavgke"