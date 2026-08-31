#!/usr/bin/env bash
# Tag -> notarized build -> GitHub release, in one command.
#
# The version is NOT passed in: it is read from project.yml, which is the
# committed source of truth (the .xcodeproj it generates is gitignored, so a
# build number that only ever lived there could never be reproduced on another
# machine). Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml,
# commit, then run this.
#
#   bash scripts/release-tagged.sh              # build 9 -> tag v1.0.0-build.9
#   bash scripts/release-tagged.sh --dry-run    # everything except tag + publish
#   bash scripts/release-tagged.sh --allow-off-main
#
# Deliberate ordering: the app is built, notarized and Gatekeeper-verified
# BEFORE the tag is pushed or the release is created. A failed build leaves no
# dangling tag and no half-published release to clean up.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DRY_RUN=0
ALLOW_OFF_MAIN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --allow-off-main) ALLOW_OFF_MAIN=1 ;;
    -h|--help)        sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# --- version comes from project.yml, never from the gitignored xcodeproj ----
MARKETING="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
BUILD="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[ -n "$MARKETING" ] || die "could not read MARKETING_VERSION from project.yml"
[ -n "$BUILD" ]     || die "could not read CURRENT_PROJECT_VERSION from project.yml"
TAG="v${MARKETING}-build.${BUILD}"
ZIP="build/macos/GloamVoiceStudio-${MARKETING}-macOS.zip"

echo "==> ${TAG}  (marketing ${MARKETING}, build ${BUILD})"

# --- guards ----------------------------------------------------------------
command -v gh        >/dev/null || die "gh CLI not found"
command -v infisical >/dev/null || die "infisical CLI not found"
command -v fastlane  >/dev/null || die "fastlane not found"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

git fetch --quiet origin main --tags
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  && die "tag $TAG already exists locally — bump CURRENT_PROJECT_VERSION in project.yml"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
  && die "tag $TAG already exists on origin — bump CURRENT_PROJECT_VERSION in project.yml"

# Releases are cut from main. The escape hatch exists because build 8 shipped
# off a branch; it should stay the exception, so it has to be asked for.
if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  if [ "$ALLOW_OFF_MAIN" -eq 1 ]; then
    echo "    WARNING: HEAD is not on origin/main — proceeding (--allow-off-main)"
  else
    die "HEAD is not an ancestor of origin/main. Merge first, or pass --allow-off-main."
  fi
fi

# --- Infisical: the CLI has no interactive login on this machine -----------
# Without a token `infisical secrets get` returns its region-picker TUI escape
# codes instead of failing, which surfaces much later as a corrupt .p12. Get a
# real token up front and validate its shape.
if [ -z "${INFISICAL_TOKEN:-}" ]; then
  [ -f secrets/env.sh ] || die "secrets/env.sh not found (holds INFISICAL_CLIENT_SECRET)"
  set -a; . secrets/env.sh; set +a
  [ -n "${INFISICAL_CLIENT_SECRET:-}" ] || die "INFISICAL_CLIENT_SECRET not set by secrets/env.sh"
  echo "==> authenticating to Infisical (universal-auth machine identity)"
  INFISICAL_TOKEN="$(infisical login --method=universal-auth \
    --client-id="${INFISICAL_CLIENT_ID:-ba1f89ac-5083-45cd-98b4-386b02e5b00b}" \
    --client-secret="$INFISICAL_CLIENT_SECRET" \
    --domain="https://infisical.tinytrashlabs.com" --silent --plain)"
  [ "${#INFISICAL_TOKEN}" -ge 40 ] \
    || die "Infisical auth failed (token length ${#INFISICAL_TOKEN}) — is the tailnet up?"
  export INFISICAL_TOKEN
fi

# --- build + notarize ------------------------------------------------------
echo "==> staging Developer ID signing material"
# shellcheck disable=SC1091
source scripts/stage-devid-signing.sh

echo "==> fastlane build_notarized  (archive + notarytool --wait + staple)"
fastlane build_notarized

[ -f "$ZIP" ] || die "expected artifact not found: $ZIP"

# --- verify Gatekeeper actually accepts it ---------------------------------
# "the build didn't error" is not the same as "a fresh Mac will open it".
echo "==> verifying Gatekeeper acceptance"
CHECK="$(mktemp -d /tmp/gvs-release-check.XXXXXX)"
ditto -x -k "$ZIP" "$CHECK"
spctl --assess --type execute -vvv "$CHECK/GloamVoiceStudio.app" 2>&1 | tee /dev/stderr \
  | grep -q "source=Notarized Developer ID" \
  || die "spctl did not report a Notarized Developer ID source"
xcrun stapler validate "$CHECK/GloamVoiceStudio.app" \
  || die "stapler validate failed — the ticket is not attached"
rm -rf "$CHECK"
echo "    Gatekeeper: accepted, notarized, stapled"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> --dry-run: stopping before tag + publish. Artifact: $ZIP"
  exit 0
fi

# --- tag, push, publish ----------------------------------------------------
echo "==> tagging $TAG and publishing the release"
git tag -a "$TAG" -m "Gloam Voice Studio ${MARKETING} (build ${BUILD})"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" \
  --title "Gloam Voice Studio ${MARKETING} (build ${BUILD}) — macOS" \
  --generate-notes

echo "==> done: $(gh release view "$TAG" --json url -q .url)"
