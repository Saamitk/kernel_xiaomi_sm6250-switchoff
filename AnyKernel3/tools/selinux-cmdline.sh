# Normalize only exact boot argument names, preserving unrelated arguments.
# Called after dump_boot and before write_boot; supports both AK3 unpackers.
normalize_selinux_cmdline() {
  local cmdfile mode;
  if [ -f "$split_img/cmdline.txt" ]; then
    cmdfile="$split_img/cmdline.txt";
    mode=cmdline;
  elif [ -f "$split_img/header" ] && grep -q '^cmdline=' "$split_img/header"; then
    cmdfile="$split_img/header";
    mode=header;
  else
    return 1;
  fi;
  awk -v mode="$mode" '
    function normalize(line, n, args, i, result) {
      n = split(line, args, /[ \t]+/);
      result = "";
      for (i = 1; i <= n; i++) {
        if (args[i] == "" || args[i] ~ /^(androidboot\.selinux|enforcing|selinux)=/)
          continue;
        result = result args[i] " ";
      }
      return result "androidboot.selinux=enforcing enforcing=1 selinux=1";
    }
    mode == "cmdline" { print normalize($0); next; }
    /^cmdline=/ { print "cmdline=" normalize(substr($0, 9)); next; }
    { print; }
  ' "$cmdfile" > "$cmdfile.selinux-new" || return 1;
  cat "$cmdfile.selinux-new" > "$cmdfile" || return 1;
  rm -f "$cmdfile.selinux-new";
}
