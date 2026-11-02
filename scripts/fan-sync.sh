#!/usr/bin/env bash
# fan-sync.sh — keep the "fan-section" patch stack riding on upstream/main.
#
# Branch layout:
#   main        mirrors https://github.com/lingyired/status-trio main (no local commits)
#   fan-section main + the FanCtl patch stack (fan section, fork feed/key, this tooling)
#
# Exit codes are load-bearing for the workflow:
#   0 = synced (or already up to date); a release was cut iff upstream moved
#   1 = usage / environment error
#   2 = (--check only) upstream moved; a rebase would be required
#   3 = rebase conflict — ABORTED, tree left untouched, alarm must fire
#   4 = build failure
#   5 = test failure
# Nothing is published on any non-zero exit. A silent, degraded package is
# considered worse than no package.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-local}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/lingyired/status-trio.git}"
BUNDLE_ID="${BUNDLE_ID:-com.yutingou.StatusTrioFan}"
APP_NAME="${APP_NAME:-Status Trio Fan}"
FEED_URL="${FEED_URL:-https://raw.githubusercontent.com/yuting-ou/status-trio/fan-section/appcast-fan.xml}"
APPCAST="$ROOT/appcast-fan.xml"

log() { printf '[fan-sync] %s\n' "$*"; }

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch upstream --tags
git fetch origin

UPSTREAM_HEAD="$(git rev-parse upstream/main)"
BASE_HEAD="$(git rev-parse main)"

if [[ "$UPSTREAM_HEAD" == "$BASE_HEAD" && "$MODE" != "--check" ]]; then
    # Even when upstream did not move, an unpushed local stack must not be
    # mistaken for a synced one.
    if [[ -z "$(git status --porcelain)" && "$(git rev-parse fan-section)" == "$(git rev-parse origin/fan-section 2>/dev/null || echo '')" ]]; then
        log "up to date (upstream/main $UPSTREAM_HEAD); nothing to do"
        exit 0
    fi
fi

if [[ "$MODE" == "--check" ]]; then
    if [[ "$UPSTREAM_HEAD" == "$BASE_HEAD" ]]; then
        log "up to date with upstream/main ($UPSTREAM_HEAD)"
        exit 0
    fi
    log "upstream moved: $BASE_HEAD -> $UPSTREAM_HEAD; rebase would be required"
    exit 2
fi

log "advancing main to upstream/main ($UPSTREAM_HEAD)"
git branch -f main upstream/main

log "rebasing fan-section onto main"
git checkout fan-section
if ! git rebase main; then
    CONFLICTED="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    git rebase --abort || true
    log "CONFLICT while rebasing onto upstream/main: $CONFLICTED"
    log "rebase aborted; fan-section left at its previous head"
    # Machine-readable marker the workflow scrapes for the alarm issue.
    echo "FAN_SYNC_CONFLICT_FILES=$CONFLICTED"
    exit 3
fi

# Fork build numbers live in upstream_build*100 + fork revision so Sparkle's
# version comparison always orders a fork build above its upstream base. The
# bundle must carry this same number, or an installed app would forever look
# "older" than the appcast item and update-loop.
UPSTREAM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
UPSTREAM_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist)"
FORK_REV="${FORK_REV:-$(git rev-list --count main..HEAD)}"
FORK_BUILD=$(( UPSTREAM_BUILD * 100 + FORK_REV ))
TAG="fan-v${UPSTREAM_VERSION}.${FORK_BUILD}"

log "building (release, version $UPSTREAM_VERSION build $FORK_BUILD)"
BUNDLE_ID="$BUNDLE_ID" APP_NAME="$APP_NAME" SU_FEED_URL="$FEED_URL" \
    APP_VERSION="$UPSTREAM_VERSION" BUILD_NUMBER="$FORK_BUILD" \
    PRIVILEGED_HELPER=0 MOBILE_BATTERY=0 \
    bash scripts/build-app.sh release no-open || exit 4

log "running test suite"
if ! swift test; then
    log "tests failed on rebased tree; nothing published"
    exit 5
fi

if [[ "$MODE" != "--ci" ]]; then
    log "local sync OK — rebase + build + tests green (no packaging in local mode)"
    exit 0
fi

# --- CI packaging: sign, appcast, release ------------------------------------
: "${SPARKLE_PRIVATE_KEY_FILE:?set SPARKLE_PRIVATE_KEY_FILE to the exported EdDSA pem for sign_update}"
ZIP="$ROOT/dist/StatusTrioFan-${UPSTREAM_VERSION}-${FORK_BUILD}.zip"

log "packaging $TAG"
ditto -c -k --keepParent "$ROOT/dist/StatusTrio.app" "$ZIP"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { log "missing Sparkle sign_update at $SIGN_UPDATE"; exit 4; }
SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$ZIP")"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S %z')"

# Prepend the new item to the appcast (before </channel>).
python3 - "$APPCAST" "$TAG" "$UPSTREAM_VERSION" "$FORK_BUILD" "$ZIP" "$SIGNATURE" "$PUBDATE" <<'PY'
import sys
path, tag, ver, build, zip_path, sig, pubdate = sys.argv[1:8]
item = f"""    <item>
      <title>Status Trio Fan {ver} (build {build})</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <pubDate>{pubdate}</pubDate>
      <enclosure url="https://github.com/yuting-ou/status-trio/releases/download/{tag}/{zip_path.split('/')[-1]}"
                 type="application/octet-stream" {sig}/>
    </item>
"""
text = open(path, encoding='utf-8').read()
open(path, 'w', encoding='utf-8').write(text.replace("  </channel>", item + "  </channel>"))
PY

git add appcast-fan.xml
git commit -m "appcast: $TAG"
git tag -f "$TAG"
git push origin main fan-section
git push -f origin "refs/tags/$TAG"

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" gh release create "$TAG" "$ZIP" \
    --title "$TAG" \
    --notes "Upstream ${UPSTREAM_VERSION} + FanCtl fan section (rebased onto $(git rev-parse --short main)). Automated fan-sync build; tests green."
log "published $TAG"
