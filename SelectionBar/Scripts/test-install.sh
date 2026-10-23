#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selectionbar-installer.XXXXXX")"
fixture_root="$(cd "$fixture_root" && pwd -P)"
fixture_pid=""
cleanup() {
  if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  /bin/rm -rf "$fixture_root"
}
trap cleanup EXIT
export SELECTIONBAR_INSTALL_APPLICATIONS_DIR="$fixture_root/Applications"
export SELECTIONBAR_INSTALL_WORK_DIR="$fixture_root/Work"
export SELECTIONBAR_INSTALL_SOURCE="$fixture_root/Source.app"
export SELECTIONBAR_INSTALL_SKIP_REGISTRATION=1
/bin/mkdir -p "$SELECTIONBAR_INSTALL_APPLICATIONS_DIR" "$SELECTIONBAR_INSTALL_WORK_DIR"
/usr/bin/ditto "$project_dir/dist/SelectionBar.app" "$SELECTIONBAR_INSTALL_SOURCE"
physical="$SELECTIONBAR_INSTALL_APPLICATIONS_DIR/SelectionBar.app"
formal="$SELECTIONBAR_INSTALL_WORK_DIR/SelectionBar.app"
reset_old() {
  /bin/rm -rf "$physical"
  /usr/bin/ditto "$SELECTIONBAR_INSTALL_SOURCE" "$physical"
  printf 'previous-version\n' > "$physical/Contents/Resources/installer-sentinel"
  /usr/bin/codesign --force --sign - "$physical" 2>/dev/null
}
assert_no_staging() {
  [ -z "$(/usr/bin/find "$SELECTIONBAR_INSTALL_APPLICATIONS_DIR" -maxdepth 1 -name '.SelectionBar.install.*' -print)" ]
}
reset_old
/bin/ln -s "$physical" "$formal"
/bin/bash "$project_dir/Scripts/install.sh" > "$fixture_root/success.log" 2>&1
[ ! -f "$physical/Contents/Resources/installer-sentinel" ]
[ "$(/usr/bin/readlink "$formal")" = "$physical" ]
[ -z "$(/usr/bin/find "$SELECTIONBAR_INSTALL_APPLICATIONS_DIR" -maxdepth 1 -name '.SelectionBar.backup.*' -print)" ]
assert_no_staging
printf '%s\n' 'PASS signed update commits and deletes only its obsolete backup'

reset_old
cat > "$fixture_root/failing-move" <<'SH'
#!/bin/bash
case "$1" in */.SelectionBar.install.*) exit 97 ;; esac
exec /bin/mv "$@"
SH
/bin/chmod 700 "$fixture_root/failing-move"
export SELECTIONBAR_INSTALL_MOVE_TOOL="$fixture_root/failing-move"
if /bin/bash "$project_dir/Scripts/install.sh" > "$fixture_root/rollback.log" 2>&1; then exit 1; fi
[ -f "$physical/Contents/Resources/installer-sentinel" ]
/usr/bin/codesign --verify --deep --strict "$physical"
assert_no_staging
printf '%s\n' 'PASS injected commit move failure restores signed previous app'

cat > "$fixture_root/failing-move" <<'SH'
#!/bin/bash
case "$1" in */.SelectionBar.install.*|*/.SelectionBar.backup.*) exit 97 ;; esac
exec /bin/mv "$@"
SH
if /bin/bash "$project_dir/Scripts/install.sh" > "$fixture_root/retained.log" 2>&1; then exit 1; fi
[ ! -e "$physical" ]
backup="$(/usr/bin/find "$SELECTIONBAR_INSTALL_APPLICATIONS_DIR" -maxdepth 1 -name '.SelectionBar.backup.*' -print)"
[ -f "$backup/Contents/Resources/installer-sentinel" ]
/usr/bin/codesign --verify --deep --strict "$backup"
/bin/mv "$backup" "$physical"
assert_no_staging
printf '%s\n' 'PASS rollback failure retains recoverable signed backup'
unset SELECTIONBAR_INSTALL_MOVE_TOOL

/bin/rm "$formal"
/bin/ln -s "$fixture_root/Unrelated.app" "$formal"
if /bin/bash "$project_dir/Scripts/install.sh" > "$fixture_root/conflict.log" 2>&1; then exit 1; fi
[ -f "$physical/Contents/Resources/installer-sentinel" ]
[ "$(/usr/bin/readlink "$formal")" = "$fixture_root/Unrelated.app" ]
assert_no_staging
/bin/rm "$formal"
/bin/ln -s "$physical" "$formal"
printf '%s\n' 'PASS conflicting Work entry rejected before app mutation'

/bin/cp /bin/sleep "$fixture_root/SelectionBar"
/usr/bin/codesign --force --sign - "$fixture_root/SelectionBar" 2>/dev/null
"$fixture_root/SelectionBar" 10 &
fixture_pid=$!
if /bin/bash "$project_dir/Scripts/install.sh" > "$fixture_root/running.log" 2>&1; then exit 1; fi
[ -f "$physical/Contents/Resources/installer-sentinel" ]
assert_no_staging
kill "$fixture_pid"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""
printf '%s\n' 'PASS running SelectionBar process blocks replacement'

/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier local.unrelated.fixture' "$SELECTIONBAR_INSTALL_SOURCE/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$SELECTIONBAR_INSTALL_SOURCE" 2>/dev/null
if /bin/bash "$project_dir/Scripts/install.sh" > "$fixture_root/id.log" 2>&1; then exit 1; fi
[ -f "$physical/Contents/Resources/installer-sentinel" ]
assert_no_staging
printf '%s\n' 'PASS unrelated signed source bundle rejected before mutation'
