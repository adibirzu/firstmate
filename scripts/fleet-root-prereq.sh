#!/usr/bin/env bash
# ONE-TIME root prerequisite for FirstMate federation (the ONLY privileged step).
# Creates the shared group + group-writable KB dir that operators coordinate through.
# Idempotent and additive — safe to re-run. Review it, then run as root:
#
#     sudo bash scripts/fleet-root-prereq.sh
#
# It changes nothing outside: (1) the `agents` group, (2) group membership for the
# listed operators, (3) /opt/agents/fleet (mode 2775 setgid). Reverse steps at the end.
set -euo pipefail
GROUP=${FM_FLEET_GROUP:-agents}
DIR=${FM_FLEET_ROOT_DIR:-/opt/agents/fleet}
# Operators default to whoever invoked sudo — NEVER a baked-in list, or running this
# on someone else's host would try to enrol names that mean nothing there. Add the
# rest of your team explicitly:
#   sudo FM_FLEET_OPERATORS="alice bob carol" bash scripts/fleet-root-prereq.sh
OPERATORS=${FM_FLEET_OPERATORS:-${SUDO_USER:-}}

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }

if [ -z "${OPERATORS// /}" ]; then
  cat >&2 <<EOF
$0: no operators to enrol.

Could not infer one (SUDO_USER is unset — you are probably in a root shell rather
than using sudo). Name them explicitly:

    sudo FM_FLEET_OPERATORS="alice bob" bash $0

Every operator must already be an OS user on this host.
EOF
  exit 1
fi

groupadd -f "$GROUP"
for u in $OPERATORS; do
  if id -u "$u" >/dev/null 2>&1; then
    usermod -aG "$GROUP" "$u"; echo "added $u to $GROUP"
  else
    echo "skip: OS user '$u' does not exist"
  fi
done

mkdir -p "$DIR/locks"
chgrp -R "$GROUP" "$DIR"
chmod -R 2775 "$DIR"        # setgid: files created here inherit the group

echo "--- verify ---"
stat -c '%A %U:%G %n' "$DIR"
echo "expect: drwxrwsr-x root:$GROUP $DIR"
echo
echo "NEXT (per operator, NO root needed):"
echo "  • group membership takes effect on your NEXT login (re-login or 'newgrp $GROUP')"
echo "  • echo 'umask 002' >> ~/.bashrc   # keep shared files group-writable"
echo "  • cd <your firstmate home> && FM_FLEET_DIR=$DIR bin/fm-fleet.sh init   # once, first operator only"
echo "  • FM_FLEET_DIR=$DIR bin/fm-fleet-join.sh <you> <scopes-csv> [accounts-csv]"
echo
echo "# Reverse (only if you ever want to undo):"
echo "#   for u in $OPERATORS; do gpasswd -d \$u $GROUP 2>/dev/null; done; groupdel $GROUP; rm -rf $DIR"
