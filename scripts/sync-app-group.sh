#!/bin/zsh
# Refresh the Mac App Store profile so it grants the App Group entitlement.
#
# Why this exists: MAC_APPSTORE_PROFILE is a static base64 blob in Infisical,
# and a provisioning profile is a snapshot of the capabilities its bundle ID
# had when it was ISSUED -- adding one later does not update it. Ship without
# regenerating and codesign happily produces a build whose entitlements claim
# something its profile doesn't grant, which App Store Connect rejects at
# upload, after a full archive.
#
# On macOS an App Group is NOT a Developer Portal resource: profiles grant
# `com.apple.security.application-groups` as the wildcard <TeamID>.*, so any
# team-prefixed identifier is self-authorizing. (The portal's `group.` prefix
# rule is iOS-only.) All that's needed is the APP_GROUPS capability on the
# bundle ID and a profile issued after it -- both done here with the API key,
# no Apple web session.
set -e

TEAM_ID="UT233385J9"
PROFILE_NAME="Gloam Voice Studio Mac App Store"
PROFILE_TYPE="MAC_APP_STORE"
STUDIO_BUNDLE="fm.gloam.studio"
# MAC_APP_DISTRIBUTION, not the generic DISTRIBUTION ("Apple Distribution")
# that also matches -- a MAC_APP_STORE profile needs the Mac App Distribution cert.
CERT_TYPE="MAC_APP_DISTRIBUTION"
MEMBERS=("fm.gloam.studio" "fm.gloam.butler")

note() { print -r -- ">> $*" >&2; }
PICK="${0:A:h}/_asc_pick.py"

bundle_resource_id() {
  asc bundle-ids list --paginate --output json 2>/dev/null | python3 "$PICK" identifier "$1"
}

for ident in $MEMBERS; do
  res="$(bundle_resource_id "$ident")"
  [ -n "$res" ] || { note "SKIP $ident -- no bundle ID registered"; continue; }
  note "Ensuring APP_GROUPS on $ident ($res)"
  asc bundle-ids capabilities add --bundle "$res" --capability APP_GROUPS >/dev/null 2>&1 || true
done

STUDIO_RES="$(bundle_resource_id "$STUDIO_BUNDLE")"
[ -n "$STUDIO_RES" ] || { print -r -- "No bundle ID for $STUDIO_BUNDLE" >&2; exit 1; }
CERT="$(asc certificates list --paginate --output json 2>/dev/null | python3 "$PICK" certificateType "$CERT_TYPE")"
[ -n "$CERT" ] || { print -r -- "No $CERT_TYPE certificate found" >&2; exit 1; }

OLD="$(asc profiles list --paginate --output json 2>/dev/null | python3 "$PICK" name "$PROFILE_NAME")"
if [ -n "$OLD" ]; then
  # Keep a copy before deleting. A deleted profile cannot be restored, and this
  # runs against the profile releases are actively built from.
  BACKUP="${TMPDIR:-/tmp}/gloam-macappstore-$OLD.provisionprofile.bak"
  asc profiles download --id "$OLD" --output "$BACKUP" >&2 \
    || { print -r -- "Refusing to delete $OLD: backup download failed" >&2; exit 1; }
  note "Backed up old profile to $BACKUP"
  note "Deleting stale profile $OLD"
  asc profiles delete --id "$OLD" --confirm >&2
fi

note "Creating $PROFILE_NAME (cert $CERT, bundle $STUDIO_RES)"
asc profiles create --name "$PROFILE_NAME" --profile-type "$PROFILE_TYPE" \
  --bundle "$STUDIO_RES" --certificate "$CERT" >/dev/null

NEW="$(asc profiles list --paginate --output json 2>/dev/null | python3 "$PICK" name "$PROFILE_NAME")"
[ -n "$NEW" ] || { print -r -- "Profile creation did not produce $PROFILE_NAME" >&2; exit 1; }
OUT="${TMPDIR:-/tmp}/gloam-macappstore.provisionprofile"
asc profiles download --id "$NEW" --output "$OUT" >/dev/null

# Prove it, rather than trusting that creation picked the capability up.
GRANTS="$(security cms -D -i "$OUT" 2>/dev/null \
  | python3 -c 'import plistlib,sys
d=plistlib.loads(sys.stdin.buffer.read())
print(" ".join(d.get("Entitlements",{}).get("com.apple.security.application-groups",[])))')"
[ -n "$GRANTS" ] || {
  print -r -- "FAIL: $NEW does not grant com.apple.security.application-groups" >&2
  exit 1; }

note "New profile $NEW grants application-groups: $GRANTS"
note "Profile: $OUT"
note "Push to Infisical as MAC_APPSTORE_PROFILE (base64):"
note "  base64 -i $OUT | pbcopy"
