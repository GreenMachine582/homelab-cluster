#!/usr/bin/env bash
# scripts/authentik-invite.sh
#
# Creates a single-use invitation and prints its public link. The admin UI's
# link uses the host the UI is on (auth.home), which a public invitee can't
# reach. Run in WSL, where the kubeconfig is. See docs/AUTHENTIK.md.
#
#   scripts/authentik-invite.sh <slug>-users [-d DAYS] [-u CREATED_BY]
#
#   <slug>-users   the group the new user joins; it must exist
#   -d DAYS        days until the link expires (default 7)
#   -u CREATED_BY  the user shown as its creator (default akadmin)
#
# Runs `ak shell` in the server pod, so it needs no API token. Revoke an
# unused invite by deleting it in Admin → Directory → Invitations.

set -euo pipefail

usage() {
  sed -n '8,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

die() { echo "authentik-invite: $*" >&2; exit 1; }

[[ ${1:-} == -h || ${1:-} == --help ]] && usage 0
(( $# >= 1 )) || usage

group=$1
shift
days=7 created_by=akadmin
while getopts ':d:u:h' opt; do
  case $opt in
    d) days=$OPTARG ;;
    u) created_by=$OPTARG ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
(( OPTIND > $# )) || usage

# The enrollment flow denies any other group too, but nothing unchecked goes
# into the pod.
[[ $group =~ ^[a-z0-9-]+-users$ ]] || die "$group: not a <slug>-users group"
[[ $days =~ ^[1-9][0-9]?$ ]] || die "-d $days: give 1 to 99 days"
[[ $created_by =~ ^[A-Za-z0-9._@-]+$ ]] || die "-u $created_by: not a username"
command -v kubectl >/dev/null || die "kubectl isn't installed"

# Values travel as environment variables, never as part of the code.
read -r -d '' code <<'PY' || true
import os, secrets
from datetime import timedelta
from django.utils.timezone import now
from authentik.core.models import Group, User
from authentik.flows.models import Flow
from authentik.stages.invitation.models import Invitation

group, days, by = os.environ["INVITE_GROUP"], int(os.environ["INVITE_DAYS"]), os.environ["INVITE_BY"]
if not Group.objects.filter(name=group).exists():
    print(f"INVITE-ERROR group {group} doesn't exist")
elif not (user := User.objects.filter(username=by).first()):
    print(f"INVITE-ERROR user {by} doesn't exist")
else:
    invite = Invitation.objects.create(
        name=f"invite-{group}-{now():%Y%m%d}-{secrets.token_hex(2)}",
        flow=Flow.objects.get(slug="homelab-invitation-enrollment"),
        single_use=True,
        expires=now() + timedelta(days=days),
        fixed_data={"invite_group": group},
        created_by=user,
    )
    print(f"INVITE-OK {invite.name} expires {invite.expires:%Y-%m-%d %H:%M %Z}")
    print(f"INVITE-LINK https://auth.green-tech-hub.com/if/flow/homelab-invitation-enrollment/?itoken={invite.pk}")
PY

out=$(kubectl -n authentik exec deploy/authentik-server -- \
  env INVITE_GROUP="$group" INVITE_DAYS="$days" INVITE_BY="$created_by" \
  ak shell -c "$code" 2>&1 | grep '^INVITE-') || die "ak shell printed no result; run it by hand to see the error"

if [[ $out == INVITE-ERROR* ]]; then
  die "${out#INVITE-ERROR }"
fi
sed -e 's/^INVITE-OK /Created /' -e 's/^INVITE-LINK //' <<<"$out"
