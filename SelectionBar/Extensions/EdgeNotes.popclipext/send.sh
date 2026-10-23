#!/bin/sh
set -eu
umask 077

handoff_dir="${HOME:?}/Library/Application Support/DeskTools Handoff"
if [ -L "$handoff_dir" ] || { [ -e "$handoff_dir" ] && [ ! -d "$handoff_dir" ]; }; then
  printf '%s\n' 'EdgeNotes 交接資料夾無法安全開啟。' >&2
  exit 1
fi
/bin/mkdir -p "$handoff_dir"
/bin/chmod 700 "$handoff_dir"

# Content travels over stdin, never in a command, URL or the clipboard.
handoff_file="$handoff_dir/SelectionBar.$(/usr/bin/uuidgen).edgetext"
(set -C; : > "$handoff_file")
trap '/bin/rm -f "$handoff_file"' 0
trap 'exit 1' HUP INT TERM
/usr/bin/head -c 1000001 > "$handoff_file"
handoff_size=$(/usr/bin/wc -c < "$handoff_file")
if [ "$handoff_size" -gt 1000000 ]; then
  printf '%s\n' '交接文字最多 1 MB。' >&2
  exit 1
fi
if [ "$handoff_size" -eq 0 ]; then exit 0; fi

# Remove only old payloads made by this action.
/usr/bin/find "$handoff_dir" -maxdepth 1 -type f -name 'SelectionBar.*.edgetext' -mmin +1440 -delete
/usr/bin/open -b local.pakwingho.edgenotes "$handoff_file"
trap - 0
