#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
expected_id="local.pakwingho.selectionbar"
source_path="${SELECTIONBAR_INSTALL_SOURCE:-$project_dir/dist/SelectionBar.app}"
physical_parent="${SELECTIONBAR_INSTALL_APPLICATIONS_DIR:-/Applications}"
formal_parent="${SELECTIONBAR_INSTALL_WORK_DIR:-/Applications}"
move_tool="${SELECTIONBAR_INSTALL_MOVE_TOOL:-/bin/mv}"
stage_path=""
backup_path=""
had_existing=0
had_formal=0
committed=0

fail() { printf '%s\n' "$*" >&2; exit 1; }
bundle_id() { /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist"; }
verify_bundle() {
  [ -d "$1" ] && [ ! -L "$1" ] || fail "Expected an app bundle: $1"
  [ "$(bundle_id "$1")" = "$expected_id" ] || fail "Refusing an unexpected bundle identifier: $1"
  /usr/bin/codesign --verify --deep --strict "$1"
}

for path in "$physical_parent" "$formal_parent" "$source_path" "$move_tool"; do
  case "$path" in /*) ;; *) fail 'Installer paths must be absolute.' ;; esac
done
[ -x "$move_tool" ] || fail 'Move tool is not executable.'
if [ -n "${SELECTIONBAR_INSTALL_MOVE_TOOL:-}" ]; then
  [ -n "${SELECTIONBAR_INSTALL_APPLICATIONS_DIR:-}" ] && [ -n "${SELECTIONBAR_INSTALL_WORK_DIR:-}" ] \
    || fail 'A test move tool requires isolated destination directories.'
fi
if [ ! -d "$source_path" ] && [ -z "${SELECTIONBAR_INSTALL_SOURCE:-}" ]; then
  /bin/bash "$project_dir/Scripts/build.sh"
fi
verify_bundle "$source_path"
/bin/mkdir -p "$physical_parent" "$formal_parent"
physical_parent="$(cd "$physical_parent" && pwd -P)"
formal_parent="$(cd "$formal_parent" && pwd -P)"
physical_path="$physical_parent/SelectionBar.app"
formal_path="$formal_parent/SelectionBar.app"
[ "$physical_path" != "$formal_path" ] || fail 'Physical and Work entries must be separate.'
if [ -e "$physical_path" ] || [ -L "$physical_path" ]; then
  verify_bundle "$physical_path"
  had_existing=1
fi
if [ -e "$formal_path" ] || [ -L "$formal_path" ]; then
  [ -L "$formal_path" ] && [ "$(/usr/bin/readlink "$formal_path")" = "$physical_path" ] \
    || fail 'Work entry already exists with a different target.'
  had_formal=1
fi
if /usr/bin/pgrep -x SelectionBar >/dev/null || /usr/bin/pgrep -x SelectionBarRuntime >/dev/null; then
  fail 'Quit SelectionBar and its running actions before updating.'
fi

cleanup() {
  result=$?
  trap - EXIT INT TERM
  if [ "$committed" -eq 0 ]; then
    if [ -n "$backup_path" ] && [ -d "$backup_path" ]; then
      # Only an expected, newly installed bundle may be removed for rollback.
      restore=1
      if [ -e "$physical_path" ] || [ -L "$physical_path" ]; then
        if [ ! -L "$physical_path" ] && [ "$(bundle_id "$physical_path" 2>/dev/null)" = "$expected_id" ]; then
          /bin/rm -rf "$physical_path" || restore=0
        else
          restore=0
        fi
      fi
      if [ "$restore" -eq 1 ] && "$move_tool" "$backup_path" "$physical_path"; then
        backup_path=""
      else
        printf 'Rollback needs attention; previous app retained at %s\n' "$backup_path" >&2
      fi
    elif [ "$had_existing" -eq 0 ] && [ -n "$stage_path" ] && [ ! -d "$stage_path" ] \
      && [ -d "$physical_path" ] && [ ! -L "$physical_path" ]; then
      if [ "$(bundle_id "$physical_path" 2>/dev/null)" = "$expected_id" ]; then
        /bin/rm -rf "$physical_path"
      fi
    fi
    if [ "$had_formal" -eq 0 ] && [ -L "$formal_path" ] \
      && [ "$(/usr/bin/readlink "$formal_path")" = "$physical_path" ]; then
      /bin/rm "$formal_path"
    fi
  fi
  if [ -n "$stage_path" ] && [ -d "$stage_path" ]; then /bin/rm -rf "$stage_path"; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage_path="$(/usr/bin/mktemp -d "$physical_parent/.SelectionBar.install.XXXXXX")"
/usr/bin/ditto "$source_path" "$stage_path"
verify_bundle "$stage_path"
# Recheck immediately before the first app rename, after staging/signature work.
if [ "$had_existing" -eq 1 ]; then
  verify_bundle "$physical_path"
elif [ -e "$physical_path" ] || [ -L "$physical_path" ]; then
  fail 'Destination appeared during preparation; update cancelled.'
fi
if [ "$had_formal" -eq 1 ]; then
  [ -L "$formal_path" ] && [ "$(/usr/bin/readlink "$formal_path")" = "$physical_path" ] \
    || fail 'Work entry changed during preparation; update cancelled.'
elif [ -e "$formal_path" ] || [ -L "$formal_path" ]; then
  fail 'Work entry appeared during preparation; update cancelled.'
fi
if /usr/bin/pgrep -x SelectionBar >/dev/null || /usr/bin/pgrep -x SelectionBarRuntime >/dev/null; then
  fail 'SelectionBar started during preparation; update cancelled.'
fi
if [ "$had_existing" -eq 1 ]; then
  backup_path="$physical_parent/.SelectionBar.backup.$(/usr/bin/uuidgen)"
  [ ! -e "$backup_path" ] || fail 'Backup destination already exists.'
  "$move_tool" "$physical_path" "$backup_path"
fi
"$move_tool" "$stage_path" "$physical_path"
if [ "$had_formal" -eq 0 ]; then /bin/ln -s "$physical_path" "$formal_path"; fi
if [ "${SELECTIONBAR_INSTALL_SKIP_REGISTRATION:-0}" != 1 ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$physical_path"
fi
committed=1
if [ -n "$backup_path" ]; then /bin/rm -rf "$backup_path"; fi
printf '%s\n' "$formal_path"
