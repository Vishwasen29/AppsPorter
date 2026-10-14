#!/usr/bin/env bash
# Builds KernelSU modules (launcher, widgets, systemui) from a Motorola lhotse dump.
#
#   ./build.sh paths [modules]            print dump paths needed (for sparse checkout)
#   ./build.sh build DUMP_DIR OUT_DIR     build the zips
#
# Env: MODULES=launcher,widgets,systemui  EXPECTED_SDK=  SIGN_SYSTEMUI=true|false
#      PLATFORM_PK8= PLATFORM_PEM=  (only used when SIGN_SYSTEMUI=true)
set -euo pipefail
shopt -s nullglob

MODULES="${MODULES:-launcher,widgets,systemui}"
EXPECTED_SDK="${EXPECTED_SDK:-}"
SIGN_SYSTEMUI="${SIGN_SYSTEMUI:-false}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# ---------- file lists (paths relative to the dump root, globs allowed) ----------
paths_launcher() { cat <<'EOF'
system_ext/priv-app/Launcher3QuickStep
system_ext/etc/permissions/privapp-permissions-com.motorola.launcher3.xml
system_ext/etc/permissions/com.motorola.launcher3*.xml
system_ext/etc/sysconfig/hiddenapi-whitelist-com.motorola.launcher3.xml
product/app/LauncherConfig
product/overlay/Launcher3QuickStep__lhotse_g__auto_generated_rro_product.apk
product/overlay/framework-rro-launcher3.apk
product/overlay/LauncherConfig-rro-grid-4x6.apk
EOF
}

paths_widgets() { cat <<'EOF'
product/app/TimeWeather
product/etc/permissions/*com.motorola.timeweatherwidget.xml
product/etc/default-permissions/default-permission-com.motorola.timeweatherwidget.xml
product/etc/sysconfig/hiddenapi-whitelist-com.motorola.timeweatherwidget.xml
EOF
}

paths_systemui() { cat <<'EOF'
system_ext/priv-app/SystemUI
system_ext/priv-app/MotoClockFace
system_ext/etc/permissions/com.android.systemui.xml
system_ext/etc/permissions/com.motorola.systemui.wallpaper_blend.xml
system_ext/etc/permissions/*com.motorola.clockface.xml
system_ext/etc/motorola/bgintents/com.motorola.clockface.bgintents.xml
system/system/etc/compatconfig/SystemUI-application-compat-config.xml
product/overlay/SystemUI__lhotse_g__auto_generated_rro_product.apk
product/overlay/MotoClockFaceOverlayLhotse.apk
product/etc/enable-disable-packages/enable-disable-com.motorola.clockface.overlay.lhotse.xml
vendor/overlay/SystemUI__lhotse__auto_generated_rro_vendor.apk
EOF
}

module_name() {
  case "$1" in
    launcher) echo "Moto Launcher Port" ;;
    widgets)  echo "Moto Widgets Port" ;;
    systemui) echo "Moto SystemUI + Lockscreen Port" ;;
  esac
}

# dump path -> path inside module
map_path() {
  case "$1" in
    system/system/*) echo "system/${1#system/system/}" ;;
    *)               echo "system/$1" ;;
  esac
}

# ---------- helpers ----------
sign_apk() {
  local apk="$1" tmp="$1.aligned"
  zipalign -p -f 4 "$apk" "$tmp"
  apksigner sign --key "$PLATFORM_PK8" --cert "$PLATFORM_PEM" --out "$apk" "$tmp"
  rm -f "$tmp"
}

triage() {
  local dir="$1" apk info shared libs pkg refs
  {
    echo ""
    echo "#### Triage: $(basename "$dir")"
    echo "| APK | package | sharedUserId | uses-library | com/motorola refs |"
    echo "|---|---|---|---|---|"
  } >> "$SUMMARY"
  while IFS= read -r apk; do
    info="$( (aapt2 dump badging "$apk" 2>/dev/null || aapt dump badging "$apk" 2>/dev/null) || true)"
    pkg="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$info" | head -1)"
    shared="$(sed -n "s/.*sharedUserId='\([^']*\)'.*/\1/p" <<<"$info" | head -1)"
    libs="$(sed -n "s/^uses-library:'\([^']*\)'.*/\1/p" <<<"$info" | paste -sd, -)"
    refs="$( (unzip -p "$apk" 'classes*.dex' 2>/dev/null | strings | grep -c 'Lcom/motorola/') || true)"
    echo "| $(basename "$apk") | ${pkg:-n/a} | ${shared:-none} | ${libs:-none} | ${refs:-0} |" >> "$SUMMARY"
  done < <(find "$dir" -name '*.apk' \( -path '*priv-app*' -o -path '*/app/*' \))
}

write_module_files() {
  local m="$1" dir="$2" id="motoport_$1"
  cat > "$dir/module.prop" <<EOF
id=$id
name=$(module_name "$m")
version=$(date +%Y.%m.%d)
versionCode=$(date +%Y%m%d)
author=auto-build
description=$(module_name "$m") extracted from Motorola lhotse dump (Android 17)
EOF

  cat > "$dir/customize.sh" <<'EOF'
#!/system/bin/sh
EXPECTED_SDK="__EXPECTED_SDK__"
CUR_SDK="$(getprop ro.build.version.sdk)"
ui_print "- ROM SDK: $CUR_SDK"
if [ -n "$EXPECTED_SDK" ] && [ "$CUR_SDK" != "$EXPECTED_SDK" ]; then
  abort "! SDK mismatch (module built for $EXPECTED_SDK). Aborting."
fi
ui_print "- Setting permissions"
set_perm_recursive "$MODPATH/system" 0 0 0755 0644 u:object_r:system_file:s0
[ -d "$MODPATH/system/vendor/overlay" ] && \
  set_perm_recursive "$MODPATH/system/vendor/overlay" 0 0 0755 0644 u:object_r:vendor_overlay_file:s0
ui_print "- Bootloop guard: module auto-disables after 3 failed boots"
EOF
  sed -i "s/__EXPECTED_SDK__/${EXPECTED_SDK}/" "$dir/customize.sh"

  cat > "$dir/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
C=$(cat "$MODDIR/.bootcount" 2>/dev/null || echo 0)
C=$((C + 1))
echo "$C" > "$MODDIR/.bootcount"
[ "$C" -ge 4 ] && touch "$MODDIR/disable"
EOF

  cat > "$dir/service.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 45
rm -f "$MODDIR/.bootcount"
EOF
}

build_module() {
  local m="$1" dump="$2" out="$3"
  local dir="$WORK/motoport_$m" pat src rel dest matched
  rm -rf "$dir"; mkdir -p "$dir/system"
  echo "== Building $m =="

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    matched=0
    for src in "$dump"/$pat; do
      matched=1
      rel="${src#"$dump"/}"
      dest="$dir/$(map_path "$rel")"
      mkdir -p "$(dirname "$dest")"
      cp -a "$src" "$dest"
    done
    if [ "$matched" = 0 ]; then echo "::warning::not found in dump: $pat"; fi
  done < <("paths_$m")

  # odex/vdex from the dump won't match your ROM
  find "$dir" -type d -name oat -prune -exec rm -rf {} + || true

  # fully replace the stock app folder if the ROM uses the same folder name
  case "$m" in
    systemui) [ -d "$dir/system/system_ext/priv-app/SystemUI" ] && touch "$dir/system/system_ext/priv-app/SystemUI/.replace" || true ;;
    launcher) [ -d "$dir/system/system_ext/priv-app/Launcher3QuickStep" ] && touch "$dir/system/system_ext/priv-app/Launcher3QuickStep/.replace" || true ;;
  esac

  if [ "$m" = "systemui" ] && [ "$SIGN_SYSTEMUI" = "true" ]; then
    echo "Re-signing priv-app APKs with provided platform key"
    while IFS= read -r apk; do sign_apk "$apk"; done < <(find "$dir" -path '*priv-app*' -name '*.apk')
  fi

  triage "$dir"
  write_module_files "$m" "$dir"

  mkdir -p "$out"
  local zip="$out/motoport-$m-$(date +%Y%m%d).zip"
  (cd "$dir" && zip -qr9 "$zip" .)
  echo "Built $zip"
}

# ---------- entrypoint ----------
cmd="${1:-}"
case "$cmd" in
  paths)
    IFS=',' read -ra mods <<<"${2:-$MODULES}"
    for m in "${mods[@]}"; do "paths_$m"; done
    ;;
  build)
    DUMP="$(realpath "${2:?dump dir}")"
    OUT="$(realpath -m "${3:-out}")"
    WORK="$(mktemp -d)"
    echo "## Module build" >> "$SUMMARY"
    IFS=',' read -ra mods <<<"$MODULES"
    for m in "${mods[@]}"; do build_module "$m" "$DUMP" "$OUT"; done
    ;;
  *)
    echo "usage: $0 paths [modules] | build DUMP_DIR OUT_DIR" >&2
    exit 1
    ;;
esac
