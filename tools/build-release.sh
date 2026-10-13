#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
WORK="$ROOT/dist/work"
NAME="navmesh_transient_fix"
SP_SRC="$ROOT/addons/sourcemod/scripting/$NAME.sp"
GD="$ROOT/addons/sourcemod/gamedata/$NAME.games.txt"
SP="$WORK/$NAME.sp"

rm -rf "$DIST"
mkdir -p "$WORK" "$DIST"

# 32-bit spcomp (SM 1.4.2) needs i386 libs on the 64-bit runner
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  sudo dpkg --add-architecture i386 >/dev/null 2>&1 || true
  sudo apt-get update -qq >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lib32stdc++6 lib32z1 zip >/dev/null 2>&1 || true
fi

resolve_version() {
  if [[ "${GITHUB_REF:-}" =~ refs/tags/v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  local subj
  subj="$(git -C "$ROOT" log -1 --pretty=%s 2>/dev/null || true)"
  if [[ "$subj" =~ (^|[^0-9])v?([0-9]+\.[0-9]+\.[0-9]+)([^0-9]|$) ]]; then
    echo "${BASH_REMATCH[2]}"
    return
  fi

  local fallback
  fallback="$(grep -oE '#define PLUGIN_VERSION "[^"]+"' "$SP_SRC" | head -1 | cut -d'"' -f2 || true)"
  if [[ -n "$fallback" && "$fallback" != "0.0.0-dev" ]]; then
    echo "$fallback"
    return
  fi

  echo "0.0.0-dev"
}

VERSION="$(resolve_version)"
echo "Plugin version: $VERSION"

sed -E "s/#define PLUGIN_VERSION \".*\"/#define PLUGIN_VERSION \"$VERSION\"/" \
  "$SP_SRC" > "$SP"

# One build with oldest compatible compiler (SM 1.4.2) — runs on 1.4 … 1.13
echo "==> SM 1.4.2 (spcomp)"
COMP142="$ROOT/tools/compilers/sm1.4.2-linux"
chmod +x "$COMP142/spcomp"
"$COMP142/spcomp" "$SP" -i"$COMP142/include" -o"$WORK/$NAME.smx"
test -s "$WORK/$NAME.smx"

STAGE="$WORK/pack"
ZIPNAME="$NAME-${VERSION}.zip"
rm -rf "$STAGE"
mkdir -p "$STAGE/addons/sourcemod/plugins" "$STAGE/addons/sourcemod/gamedata" "$STAGE/addons/sourcemod/scripting"
cp "$WORK/$NAME.smx" "$STAGE/addons/sourcemod/plugins/$NAME.smx"
cp "$GD" "$STAGE/addons/sourcemod/gamedata/$NAME.games.txt"
cp "$SP" "$STAGE/addons/sourcemod/scripting/$NAME.sp"
cp "$ROOT/README.md" "$STAGE/README.md"

(
  cd "$STAGE"
  zip -r "$DIST/$ZIPNAME" README.md addons
)

echo "OK: $DIST/$ZIPNAME"
ls -la "$DIST/$ZIPNAME"
