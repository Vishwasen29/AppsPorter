#!/usr/bin/env bash
# build_moto_launcher_v4.sh -- Moto Launcher3 (Android 17 dump) as a KernelSU/Magisk module.
#
# LAUNCHER ONLY. SystemUI (lockscreen/keyguard) is deliberately NOT supported: Moto's SystemUI
# is signed with Motorola's platform key and uses sharedUserId android.uid.systemui, so it
# cannot replace another ROM's SystemUI.
#
# What changed vs v3:
#   * git symlinks in the dump (stored as tiny text files) are resolved to the real file
#   * downloads are strict: any HTTP error / LFS pointer / bad ELF / bad zip fails the build
#   * only launcher3 permission XMLs are shipped (v3 shipped ~226 unrelated ones)
#   * the moto-*.jar shared libraries the launcher declares as required are shipped too
#   * customize.sh requires the SDK the APK actually needs (read from the APK when aapt exists)
#   * service.sh logs the boot and disables the module itself if boot never completes
#
# Needs: bash>=4.4, curl, jq, zip, unzip, python3.  Optional: aapt/aapt2 (manifest check).
# Usage:  ./build_moto_launcher_v4.sh list | build
# Env:    REF, APPS (regex, default launcher3), LIBS, MIN_SDK, OUT, ZIP, HOST, PROJ_PATH
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

HOST="${HOST:-https://dumps.tadiphone.dev}"
PROJ_PATH="${PROJ_PATH:-dumps/motorola/lhotse}"
REF="${REF:-user-17-VWL35HV-19-ST9.2-8c0861-release-keys}"
APPS="${APPS:-launcher3}"
LIBS="${LIBS:-moto-settings moto-checkin moto-core_services}"
MIN_SDK="${MIN_SDK:-37}"
OUT="${OUT:-$PWD/moto_launcher_module}"
ZIP="${ZIP:-$PWD/moto_launcher_module.zip}"

PROJ="$(printf '%s' "$PROJ_PATH" | sed 's#/#%2F#g')"
API="$HOST/api/v4/projects/$PROJ/repository"
RAW="$HOST/$PROJ_PATH/-/raw/$REF"

# dump dir | module dir
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
for t in curl jq zip unzip python3 awk; do command -v "$t" >/dev/null || die "missing tool: $t"; done

enc()     { jq -rn --arg v "$1" '$v|@uri'; }
enc_path(){ jq -rn --arg v "$1" '$v|split("/")|map(@uri)|join("/")'; }

# http_get URL OUTFILE -> prints the HTTP status code (000 on transport failure)
http_get() { curl -sS -L --retry 3 --retry-delay 2 -o "$2" -w '%{http_code}' "$1" </dev/null || true; }

# tree_to OUTFILE PATH [recursive] -> lines "type<TAB>path". 404 => empty. Anything else => fail.
tree_to() {
  local out="$1" p rec="${3:-false}" page=1 code body="$TMP/page.json"
  p="$(enc "$2")"; : > "$out"
  while :; do
    code="$(http_get "$API/tree?ref=$(enc "$REF")&path=$p&recursive=$rec&per_page=100&page=$page" "$body")"
    case "$code" in
      200) ;;
      404) return 0 ;;
      *)   echo "ERROR: tree API returned HTTP $code for '$2' (page $page)" >&2; return 1 ;;
    esac
    [ "$(jq length "$body")" -eq 0 ] && break
    jq -r '.[]|"\(.type)\t\(.path)"' "$body" >> "$out"
    page=$((page+1))
  done
}

# fetch_raw DUMP_PATH DEST -> strict download
fetch_raw() {
  local code
  mkdir -p "$(dirname "$2")"
  code="$(http_get "$RAW/$(enc_path "$1")" "$2")"
  if [ "$code" != 200 ]; then echo "ERROR: HTTP $code for $1" >&2; rm -f "$2"; return 1; fi
  if head -c 200 "$2" | grep -aq 'git-lfs.github.com/spec'; then
    echo "ERROR: Git LFS pointer instead of content: $1" >&2; rm -f "$2"; return 1
  fi
}

# magic_ok FILE -> does the content match what the extension promises?
magic_ok() {
  case "$1" in
    *.so)        [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] ;;
    *.apk|*.jar) [ "$(head -c2 "$1")" = PK ] ;;
    *)           return 0 ;;
  esac
}

# norm PATH -> collapse "." and ".." (no leading slash)
norm() {
  local IFS=/ part out=()
  for part in $1; do
    case "$part" in
      ''|.) ;;
      ..)   if [ "${#out[@]}" -gt 0 ]; then unset 'out[-1]'; fi ;;
      *)    out+=("$part") ;;
    esac
  done
  IFS=/; printf '%s' "${out[*]}"
}

# device path (/system/framework/x.jar) -> path inside the dump
dev2dump() {
  case "$1" in
    /system/*)                              echo "system/system/${1#/system/}" ;;
    /system_ext/*|/product/*|/vendor/*|/odm/*) echo "${1#/}" ;;
    *) echo "ERROR: cannot map device path $1" >&2; return 1 ;;
  esac
}
# device path -> path inside the module
dev2mod() {
  case "$1" in
    /system/*)                                 echo "$OUT$1" ;;
    /system_ext/*|/product/*|/vendor/*|/odm/*) echo "$OUT/system$1" ;;
    *) echo "ERROR: cannot map device path $1" >&2; return 1 ;;
  esac
}
resolve_link() { # dump_path_of_link  link_target -> dump path of the real file
  case "$2" in
    /*) dev2dump "$2" ;;
    *)  norm "$(dirname "$1")/$2" ;;
  esac
}

# fetch_file DUMP_PATH DEST [depth] -> download; if a .so/.jar/.apk turns out to be a
# git-symlink stub (tiny one-line text file), follow it and fetch the real target instead.
fetch_file() {
  local dp="$1" dest="$2" depth="${3:-0}" tgt
  fetch_raw "$dp" "$dest" || return 1
  magic_ok "$dest" && return 0
  if [ "$depth" -lt 4 ] && [ "$(wc -c <"$dest")" -le 512 ] && [ "$(wc -l <"$dest")" -eq 0 ]; then
    tgt="$(tr -d '\r' <"$dest")"
    tgt="$(resolve_link "$dp" "$tgt")" || return 1
    echo "  symlink: $dp -> $tgt"
    rm -f "$dest"
    fetch_file "$tgt" "$dest" $((depth+1))
    return
  fi
  echo "ERROR: $dp is not a valid ${dest##*.} file" >&2; rm -f "$dest"; return 1
}

# match_dirs BASE OUTFILE -> app dirs under BASE whose name matches $APPS
match_dirs() {
  tree_to "$TMP/dirs.txt" "$1" false || exit 1
  awk -F'\t' '$1=="tree"{print $2}' "$TMP/dirs.txt" | grep -iE "/[^/]*(${APPS})[^/]*\$" > "$2" || true
  if grep -qi 'systemui' "$2"; then
    die "APPS='$APPS' matched a SystemUI directory. SystemUI is not supported (platform-signed, sharedUserId)."
  fi
}

list_cmd() {
  local b src
  for b in "${BASES[@]}"; do
    src="${b%%|*}"; match_dirs "$src" "$TMP/m.txt"; cat "$TMP/m.txt"
  done
}

check_apk() { # optional manifest sanity check (needs aapt/aapt2)
  local apk="$1" tool dump pkg sdk
  tool="$(command -v aapt2 || command -v aapt || true)"
  [ -n "$tool" ] || { warn "aapt not installed: skipping package/minSdk check (MIN_SDK=$MIN_SDK)"; return 0; }
  dump="$("$tool" dump badging "$apk" 2>/dev/null)" || { warn "aapt could not read $apk"; return 0; }
  pkg="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$dump" | head -1)"
  sdk="$(sed -n "s/^sdkVersion:'\([0-9]*\)'.*/\1/p" <<<"$dump" | head -1)"
  if [ -n "$pkg" ] && [ "$pkg" != com.motorola.launcher3 ]; then die "unexpected package '$pkg' in $apk"; fi
  if [ -n "$sdk" ] && [ "$sdk" -gt "$MIN_SDK" ]; then MIN_SDK="$sdk"; fi
  echo "  manifest: package=${pkg:-?} minSdk=${sdk:-?}"
}

build_cmd() {
  [ -n "$OUT" ] && [ "$OUT" != / ] || die "refusing to use OUT='$OUT'"
  rm -rf "$OUT"; mkdir -p "$OUT/system"
  local b src dst dir f x libre jar dp found=0

  # 1) the app(s)
  for b in "${BASES[@]}"; do
    src="${b%%|*}"; dst="${b##*|}"
    match_dirs "$src" "$TMP/match.txt"
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      echo "[app] $dir"
      tree_to "$TMP/files.txt" "$dir" true || exit 1
      awk -F'\t' '$1=="blob"{print $2}' "$TMP/files.txt" | grep -vE '/oat/|\.(odex|vdex|art)$' > "$TMP/blobs.txt" || true
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        fetch_file "$f" "$OUT/$dst/${f#"$src"/}" || exit 1
      done < "$TMP/blobs.txt"
      found=$((found+1))
    done < "$TMP/match.txt"
  done
  [ "$found" -gt 0 ] || die "nothing matched APPS='$APPS'"
  local apk; apk="$(find "$OUT" -name '*.apk' | head -1)"
  [ -n "$apk" ] || die "no APK downloaded"
  check_apk "$apk"

  # 2) launcher3 permission/feature XMLs + the XMLs of the shared libraries it requires
  libre="$(echo "$LIBS" | tr ' ' '|')"
  for b in "${PERMS[@]}"; do
    src="${b%%|*}"; dst="${b##*|}"
    tree_to "$TMP/p.txt" "$src" false || exit 1
    awk -F'\t' '$1=="blob"{print $2}' "$TMP/p.txt" \
      | grep -E "/(privapp-permissions-com\.motorola\.launcher3|com\.motorola\.launcher3[^/]*|${libre})\.xml\$" > "$TMP/pm.txt" || true
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo "[perm] $f"
      fetch_file "$f" "$OUT/$dst/${f#"$src"/}" || exit 1
    done < "$TMP/pm.txt"
  done
  find "$OUT" -name 'privapp-permissions-com.motorola.launcher3.xml' | grep -q . \
    || die "privapp-permissions-com.motorola.launcher3.xml not found (priv-app would bootloop/crash without it)"

  # 3) shared-library jars named in those XMLs (the launcher declares them required=true)
  : > "$TMP/jars.txt"
  for x in $LIBS; do
    f="$(find "$OUT" -type f -name "$x.xml" | head -1)"
    [ -n "$f" ] || die "library XML $x.xml not found in the dump"
    grep -oE 'file="[^"]+"' "$f" | sed 's/^file="//; s/"$//' >> "$TMP/jars.txt"
  done
  sort -u "$TMP/jars.txt" -o "$TMP/jars.txt"
  [ -s "$TMP/jars.txt" ] || die "no <library file=...> entries found"
  while IFS= read -r jar; do
    [ -n "$jar" ] || continue
    echo "[lib] $jar"
    dp="$(dev2dump "$jar")" || exit 1
    fetch_file "$dp" "$(dev2mod "$jar")" || exit 1
  done < "$TMP/jars.txt"

  write_module_files
  validate
  rm -f "$ZIP"; (cd "$OUT" && zip -qr9 "$ZIP" .)
  echo "Done -> $ZIP  (min SDK $MIN_SDK)"
}

validate() {
  local f n=0
  while IFS= read -r f; do
    case "$f" in
      *.so)        magic_ok "$f" || die "not an ELF file: ${f#"$OUT"/}" ;;
      *.apk|*.jar) { magic_ok "$f" && unzip -tq "$f" >/dev/null 2>&1; } || die "corrupt zip/apk/jar: ${f#"$OUT"/}" ;;
      *.xml)       python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$f" 2>/dev/null \
                     || die "malformed XML: ${f#"$OUT"/}" ;;
    esac
    n=$((n+1))
  done < <(find "$OUT" -type f)
  [ -z "$(find "$OUT" -type f \( -path '*/oat/*' -o -name '*.odex' -o -name '*.vdex' \))" ] || die "precompiled oat leaked into the module"
  echo "validated $n files"
}

write_module_files() {
cat > "$OUT/module.prop" <<'EOF'
id=MotoLauncherA17
name=Moto Launcher3 (lhotse A17) - launcher only
version=4.0
versionCode=4
author=you
description=Moto Launcher3 plus the moto-*.jar libraries it requires. Does NOT touch SystemUI or the lockscreen. Self-disables if boot never completes.
EOF

cat > "$OUT/customize.sh" <<'EOF'
API="${API:-$(getprop ro.build.version.sdk)}"
[ "$BOOTMODE" = true ] || abort "! Install from the KernelSU/Magisk app, not recovery"
[ "$API" -ge __MIN_SDK__ ] || abort "! This launcher needs Android SDK __MIN_SDK__+ (this device reports $API)"
ui_print "- SDK $API OK"
if [ -d /data/adb/modules/MotoCore ] && [ ! -f /data/adb/modules/MotoCore/disable ] && [ ! -f /data/adb/modules/MotoCore/remove ]; then
  ui_print "! Moto Core is active. If it also ships moto-*.jar libs,"
  ui_print "! the two copies may clash. Disable Moto Core if the launcher crashes."
fi
ui_print "- Launcher only: stock SystemUI/lockscreen are untouched"
ui_print "- Pick it in Settings > Apps > Default apps > Home app"
ui_print "- Boot log: /data/local/tmp/moto_launcher_boot.txt"
set_perm_recursive "$MODPATH" 0 0 0755 0644
EOF
sed -i "s/__MIN_SDK__/$MIN_SDK/g" "$OUT/customize.sh"

cat > "$OUT/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
# counts boots that never reach boot_completed; 2 in a row => module disables itself
M=${0%/*}
[ -f "$M/disable" ] && exit 0
n=$(cat "$M/.bc" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$M/.bc"
if [ "$n" -gt 1 ]; then
  touch "$M/disable"; rm -f "$M/.bc"
  echo "disabled by post-fs-data: $n boots without completing" > /data/local/tmp/moto_launcher_disabled.txt
fi
EOF

cat > "$OUT/service.sh" <<'EOF'
#!/system/bin/sh
M=${0%/*}
LOG=/data/local/tmp/moto_launcher_boot.txt
logcat -b all -v threadtime -f "$LOG" -r 8000 -n 2 &
LPID=$!
i=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$i" -lt 100 ]; do sleep 3; i=$((i+1)); done
if [ "$(getprop sys.boot_completed)" != 1 ]; then
  # stuck (e.g. "Phone is starting"): disable ourselves and reboot into a clean boot
  touch "$M/disable"
  echo "boot did not complete within 300s; module disabled" > /data/local/tmp/moto_launcher_disabled.txt
  sync; reboot
  exit 0
fi
rm -f "$M/.bc"
sleep 30
{
  echo "== dumpsys package"; dumpsys package com.motorola.launcher3 | head -80
  echo "== home resolver";   cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
} > /data/local/tmp/moto_launcher_pkg.txt 2>&1
sleep 60
kill "$LPID" 2>/dev/null
EOF

cat > "$OUT/uninstall.sh" <<'EOF'
#!/system/bin/sh
rm -f /data/local/tmp/moto_launcher_boot.txt* /data/local/tmp/moto_launcher_pkg.txt /data/local/tmp/moto_launcher_disabled.txt
EOF
}

case "${1:-}" in
  list)  list_cmd ;;
  build) build_cmd ;;
  *)     echo "usage: $0 {list|build}"; exit 1 ;;
esac
