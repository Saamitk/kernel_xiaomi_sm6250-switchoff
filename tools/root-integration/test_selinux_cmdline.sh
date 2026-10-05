#!/bin/sh
# Exercise the exact installer helper without touching a boot image/device.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/AnyKernel3/tools/selinux-cmdline.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
split_img=$tmp
for mode in cmdline header; do
  for args in '' 'console=tty0' \
    'console=tty0 androidboot.selinux=permissive enforcing=0 selinux=0 foo=bar' \
    'androidboot.selinux=enforcing enforcing=1 selinux=1' \
    'androidboot.selinux=disabled androidboot.selinux=permissive enforcing=0 enforcing=1 selinux=0 selinux=1'; do
    rm -f "$tmp/cmdline.txt" "$tmp/header"
    if [ "$mode" = header ]; then
      file=$tmp/header
      printf 'pagesize=4096\ncmdline=%s\nname=test\n' "$args" > "$file"
    else
      file=$tmp/cmdline.txt
      printf '%s\n' "$args" > "$file"
    fi
    normalize_selinux_cmdline
    cp "$file" "$tmp/first"
    normalize_selinux_cmdline
    cmp "$file" "$tmp/first"
    python3 - "$file" "$mode" "$args" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
if sys.argv[2] == 'header':
    assert text.startswith('pagesize=4096\n') and text.endswith('\nname=test\n')
    text = next(line[8:] for line in text.splitlines() if line.startswith('cmdline='))
keys = {'androidboot.selinux', 'enforcing', 'selinux'}
keep = [x for x in sys.argv[3].split() if x.split('=')[0] not in keys]
assert text.split() == keep + ['androidboot.selinux=enforcing', 'enforcing=1', 'selinux=1']
PY
  done
done
rm -f "$tmp/cmdline.txt" "$tmp/header"
if normalize_selinux_cmdline; then
  echo 'FAIL: accepted missing boot metadata' >&2
  exit 1
fi
echo 'SELinux boot argument tests passed (both unpackers, duplicates, idempotence, missing metadata)'

# Exercise the actual installer source/normalize/write sequence after dump_boot
# changes cwd, rather than only sourcing the helper directly from the test.
mkdir -p "$tmp/package/tools" "$tmp/package/ramdisk" "$tmp/package/split_img"
cp "$ROOT/AnyKernel3/tools/selinux-cmdline.sh" "$tmp/package/tools/"
awk '/^dump_boot;/ { copying=1 } copying { print } /^write_boot;/ { exit }'   "$ROOT/AnyKernel3/anykernel.sh" > "$tmp/install-sequence.sh"
(
  home="$tmp/package"
  split_img="$home/split_img"
  printf 'cmdline=console=tty0 androidboot.selinux=permissive\n' > "$split_img/header"
  dump_boot() { cd "$home/ramdisk"; }
  abort() { echo "$*" >&2; exit 1; }
  write_boot() {
    grep -qx 'cmdline=console=tty0 androidboot.selinux=enforcing enforcing=1 selinux=1' "$split_img/header"
    touch "$home/write-reached"
  }
  cd "$home"
  . "$tmp/install-sequence.sh"
)
test -f "$tmp/package/write-reached"
echo 'Installer post-dump working-directory regression passed'
