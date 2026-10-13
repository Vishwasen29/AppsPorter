#!/usr/bin/env bash
# v3: Moto launcher + optional SystemUI (lockscreen) via WITH_SYSTEMUI=1, modeled on reiryuki/Moto-Launcher-30-Magisk-Module.
# Needs bash, curl, jq, zip and internet.  Usage:
#   ./build_moto_launcher_v2.sh list
#   ./build_moto_launcher_v2.sh build
# APPS='regex' to change which app dirs are picked (default: launcher3 quickstep).
set -euo pipefail

HOST="https://dumps.tadiphone.dev"
PROJ="dumps%2Fmotorola%2Flhotse"
REF="${REF:-user-17-VWL35HV-19-ST9.2-8c0861-release-keys}"
if [ "${WITH_SYSTEMUI:-0}" = 1 ]; then APPS="${APPS:-launcher3|systemui}"; else APPS="${APPS:-launcher3}"; fi
OUT="${OUT:-$PWD/moto_launcher_module}"
API="$HOST/api/v4/projects/$PROJ/repository"
RAW="$HOST/dumps/motorola/lhotse/-/raw/$REF"

BASES=(
  "system/system/priv-app|system/priv-app"
  "system/system/app|system/app"
  "system_ext/priv-app|system/system_ext/priv-app"
  "system_ext/app|system/system_ext/app"
  "product/priv-app|system/product/priv-app"
  "product/app|system/product/app"
)
PERMS=(
  "system/system/etc/permissions|system/etc/permissions"
  "system_ext/etc/permissions|system/system_ext/etc/permissions"
  "product/etc/permissions|system/product/etc/permissions"
)

enc() { jq -rn --arg v "$1" '$v|@uri'; }
tree() { # path [recursive]
  local p; p="$(enc "$1")"; local page=1 rec="${2:-false}" res
  while :; do
    res="$(curl -fsS "$API/tree?ref=$REF&path=$p&recursive=$rec&per_page=100&page=$page" 2>/dev/null)" || return 0
    [ "$(jq length <<<"$res")" -eq 0 ] && break
    jq -r '.[]|"\(.type)\t\(.path)"' <<<"$res"; page=$((page+1))
  done
}
fetch() {
  mkdir -p "$(dirname "$2")"
  curl -fsSL "$RAW/$(printf '%s' "$1" | sed 's/ /%20/g')" -o "$2"
  if head -c 60 "$2" | grep -q 'git-lfs'; then echo "  ! LFS pointer: $1"; rm -f "$2"; fi
}
dirs() { tree "$1" | awk -F'\t' '$1=="tree"{print $2}' | grep -iE "/[^/]*($APPS)[^/]*$" || true; }

list_cmd() { for b in "${BASES[@]}"; do dirs "${b%%|*}"; done; }

build_cmd() {
  rm -rf "$OUT"; mkdir -p "$OUT/system"; : > "$OUT/package.txt"
  for b in "${BASES[@]}"; do
    src="${b%%|*}"; dst="${b##*|}"
    while read -r dir; do
      [ -z "$dir" ] && continue
      echo "[app] $dir"
      tree "$dir" true | awk -F'\t' '$1=="blob"{print $2}' \
        | grep -vE '/oat/|\.(odex|vdex|art)$' | while read -r f; do   # NO precompiled oat
          fetch "$f" "$OUT/$dst/${f#"$src"/}"
        done
      echo "$(basename "$dir")" >> "$OUT/appdirs.txt"
    done < <(dirs "$src")
  done
  [ -s "$OUT/appdirs.txt" ] || { echo "Nothing matched APPS='$APPS'"; exit 1; }
  for b in "${PERMS[@]}"; do   # privapp-permissions whitelists (missing => bootloop)
    src="${b%%|*}"; dst="${b##*|}"
    tree "$src" | awk -F'\t' '$1=="blob"{print $2}' | grep -iE 'moto|launcher' | while read -r f; do
      echo "[perm] $f"; fetch "$f" "$OUT/$dst/${f#"$src"/}"
    done
  done
  # package names for KSU superuser allow-list (best effort)
  echo "com.motorola.launcher3" >> "$OUT/package.txt"
  [ "${WITH_SYSTEMUI:-0}" = 1 ] && echo "com.android.systemui" >> "$OUT/package.txt"
  cp "$OUT/package.txt" "$OUT/UNMOUNT_OFF_FOR.txt"
  write_module_files
  (cd "$OUT" && zip -qr9 "../moto_launcher_module.zip" .)
  echo "Done -> $(dirname "$OUT")/moto_launcher_module.zip"
}

write_module_files() {
cat > "$OUT/module.prop" <<'EOF'
id=MotoLauncherA17
name=Moto Launcher (lhotse A17)
version=2.0
versionCode=2
author=you
description=Moto launcher only. Requires Moto Core module. Does NOT touch stock launcher or SystemUI.
EOF

cat > "$OUT/customize.sh" <<'EOF'
[ "$BOOTMODE" = true ] || abort "! Install from the KernelSU app only"
[ "$API" -ge 34 ] || abort "! Needs Android 14+ (SDK $API found)"
ui_print "- SDK $API"
[ -d /data/adb/modules/MotoCore ] || abort "! Install Moto Core module first: github.com/reiryuki/Moto-Core-Magisk-Module"
rm -f /data/adb/modules/MotoCore/remove /data/adb/modules/MotoCore/disable

# back up current home app's data before anything changes
HP=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -1 | cut -d/ -f1)
if [ -n "$HP" ] && [ -d "/data/data/$HP" ]; then
  B=/data/adb/moto_launcher_backup/$HP
  mkdir -p "$B" && cp -a "/data/data/$HP/." "$B/" 2>/dev/null
  ui_print "- Backed up $HP data to $B"
fi

# SystemUI (lockscreen): put Moto's copy into the stock SystemUI's exact directory
SU=$(find "$MODPATH/system" -maxdepth 4 -type d -iname '*systemui*' | head -1)
if [ -n "$SU" ]; then
  STOCK=$(pm path com.android.systemui | head -1 | cut -d: -f2)
  [ -n "$STOCK" ] || abort "! Can't locate stock SystemUI"
  SD=$(dirname "$STOCK")
  case "$SD" in /system/*) T="$MODPATH$SD" ;; *) T="$MODPATH/system$SD" ;; esac
  if [ "$SU" != "$T" ]; then mkdir -p "$T"; cp -af "$SU"/. "$T"/; rm -rf "$SU"; fi
  touch "$T/.replace"
  basename "$T" >> "$MODPATH/appdirs.txt"
  ui_print "- Moto SystemUI will replace stock at $SD"
fi

# hide precompiled oat of our apps only (device framework differs)
for d in $(cat "$MODPATH/appdirs.txt"); do
  for p in $(find "$MODPATH/system" -type d -name "$d"); do
    REPLACE="$REPLACE ${p#$MODPATH}/oat"
  done
done
set_perm_recursive "$MODPATH" 0 0 0755 0644
EOF

cat > "$OUT/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
M=${0%/*}
n=$(cat "$M/.bc" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$M/.bc"
[ "$n" -gt 2 ] && { touch "$M/disable"; rm -f "$M/.bc"; }
EOF

cat > "$OUT/service.sh" <<'EOF'
#!/system/bin/sh
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
sleep 20; rm -f "${0%/*}/.bc"
EOF

cat > "$OUT/uninstall.sh" <<'EOF'
#!/system/bin/sh
pm uninstall com.motorola.launcher3 >/dev/null 2>&1
rm -f /data/adb/moto_launcher_backup/.keep
EOF
}

case "${1:-}" in list) list_cmd;; build) build_cmd;; *) echo "usage: $0 {list|build}"; exit 1;; esac
