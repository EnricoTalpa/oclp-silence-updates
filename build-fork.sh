#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# build-fork.sh — Build the patched OpenCore Legacy Patcher app
# with the "Silence Update Notifications" menu item
#
# Usage:   bash build-fork.sh [OCLP_tag]        (default: 2.5.1)
# Output:  <workdir>/OpenCore-Legacy-Patcher/dist/OpenCore-Patcher.app
#
# Requirements (once):
#   - Python 3.11 (python.org build recommended by OCLP; see SOURCE.md
#     in the OCLP repo)
#   - OCLP dependencies:  python3.11 -m pip install -r \
#       <workdir>/OpenCore-Legacy-Patcher/requirements.txt
#
# Notes:
#   - The included patch sets target_arch="x86_64" (it was built for an
#     Intel 2009 Mac mini). On Apple Silicon, edit the spec back to
#     target_arch="universal2" after applying the patch.
#   - The patched fork disables the in-app auto-updater: updating to an
#     official release would silently remove the menu item. Re-run this
#     script on every new OCLP release instead.
#   - No prebuilt binaries are distributed: everyone builds their own.
# ══════════════════════════════════════════════════════════════════

TAG="${1:-2.5.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/fork/oclp-silence-updates-$TAG.patch"
COMPANION="$HERE/resetta_aggiornamenti_bash.sh"
WORK="${OCLP_BUILD_DIR:-$HOME/oclp-fork-build-area}"
REPO="$WORK/OpenCore-Legacy-Patcher"

# Pick a Python 3.11 (fall back to any python3)
for P in python3.11 /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11 python3; do
    if command -v "$P" >/dev/null 2>&1; then
        if "$P" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 11) else 1)' 2>/dev/null; then
            PYTHON="$P"; break
        fi
        [ -z "$PYTHON_ANY" ] && PYTHON_ANY="$P"
    fi
done
PYTHON="${PYTHON:-${PYTHON_ANY:-}}"
if [ -z "$PYTHON" ]; then
    echo "❌ No python3 found. Install Python 3.11 (python.org) and retry."
    exit 1
fi

[ -f "$PATCH" ] || { echo "❌ Patch not found: $PATCH"; exit 1; }
[ -f "$COMPANION" ] || { echo "❌ Companion not found: $COMPANION"; exit 1; }

echo "── OCLP fork build (tag $TAG) ──"
echo "  Python : $($PYTHON --version 2>&1)"
echo "  Workdir: $WORK"
echo ""

# 1. Clone OCLP at the tag (reuse the checkout if present, keep caches)
if [ ! -d "$REPO/.git" ]; then
    echo "[1/4] Cloning OpenCore-Legacy-Patcher @ $TAG…"
    mkdir -p "$WORK"
    git clone --depth 1 --branch "$TAG" \
        https://github.com/dortania/OpenCore-Legacy-Patcher "$REPO" || exit 1
else
    echo "[1/4] Reusing checkout at $REPO"
fi

# 2. Clean sources, apply the patch, copy the companion
echo "[2/4] Applying patch…"
cd "$REPO" || exit 1
git checkout -- . 2>/dev/null
rm -f opencore_legacy_patcher/wx_gui/gui_silence_updates.py
if ! git apply "$PATCH"; then
    echo "❌ Patch failed to apply (already applied, or a different release)."
    exit 1
fi
mkdir -p "Resetta-Aggiornamenti"
cp "$COMPANION" "Resetta-Aggiornamenti/resetta_aggiornamenti_bash.sh"
bash -n "Resetta-Aggiornamenti/resetta_aggiornamenti_bash.sh" || exit 1
echo "      ✓ patch + companion in place"

# 3. Build (assets + app + pkgs; downloads are cached in the checkout)
echo "[3/4] Building (this takes a few minutes)…"
"$PYTHON" Build-Project.command || { echo "❌ Build failed"; exit 1; }
[ -d "dist/OpenCore-Patcher.app" ] || { echo "❌ dist/OpenCore-Patcher.app missing"; exit 1; }
echo "      ✓ dist/OpenCore-Patcher.app"

# 4. Done
echo "[4/4] Done:"
echo "      $REPO/dist/OpenCore-Patcher.app"
echo ""
echo "Deploy (example, over SSH):"
echo "  tar -czf /tmp/OpenCore-Patcher-$TAG-fork.tar.gz -C dist OpenCore-Patcher.app"
echo "  scp /tmp/OpenCore-Patcher-$TAG-fork.tar.gz user@mac:"
echo "  ssh user@mac 'tar -xzf OpenCore-Patcher-$TAG-fork.tar.gz -C ~/Applications'"
echo ""
echo "Remember: the fork's auto-updater is disabled on purpose —"
echo "re-run this script on every new OCLP release."
