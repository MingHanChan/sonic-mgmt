#!/usr/bin/env bash
#
# Preflight: the host and the swss container must agree on the wall clock AND
# the timezone.
#
# Every orchestrator here scopes its measurement with a --since marker produced
# by the HOST's `date`, then compares it against timestamps written INSIDE the
# swss container (sairedis.rec holds local-time strings, not epochs). If the two
# disagree the failure is silent and asymmetric:
#
#   host ahead of container (e.g. host CST/UTC+8, container UTC)
#       -> the marker is in the container's future, --since filters everything
#          out and you get "No route create ops found". Loud, at least.
#   host behind the container
#       -> the marker is in the container's past, so the window silently folds
#          in records from EARLIER runs and T comes out far too large. This one
#          produces a plausible-looking number that is simply wrong.
#
# Usage:  ./check_clock_skew.sh [container]      (default: swss)
# Exits 0 when aligned, 1 otherwise.
#
set -euo pipefail

CONTAINER="${1:-swss}"
TOLERANCE="${2:-2}"     # seconds

HOST_S="$(date +"%Y-%m-%d %H:%M:%S")"
CTR_S="$(docker exec "$CONTAINER" date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")"
if [ -z "$CTR_S" ]; then
    echo "ERROR: cannot run 'date' in the '$CONTAINER' container -- is it running," >&2
    echo "and does this user have docker access?" >&2
    exit 1
fi

# Render both as the LOCAL time each side believes it is, then interpret both
# with the host's timezone. A timezone mismatch therefore shows up as a large
# offset here, exactly like a clock mismatch would -- which is what we want,
# since both corrupt --since in the same way.
SKEW=$(( $(date -d "$CTR_S" +%s) - $(date -d "$HOST_S" +%s) ))
echo "clock: host '$HOST_S' vs $CONTAINER '$CTR_S' -> skew ${SKEW}s"

if [ "${SKEW#-}" -gt "$TOLERANCE" ]; then
    echo "ERROR: the '$CONTAINER' container's wall clock/timezone is ${SKEW}s away from" >&2
    echo "the host's, so a host-generated --since marker cannot be compared against" >&2
    echo "the container-written timestamps in sairedis.rec. Align the container's" >&2
    echo "timezone with the host's (/etc/localtime, /etc/timezone) and re-run." >&2
    exit 1
fi
