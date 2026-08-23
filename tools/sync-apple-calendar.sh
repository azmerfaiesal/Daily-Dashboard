#!/usr/bin/env bash
#
# Push today's Apple Calendar events into the Daily Dashboard.
#
# The dashboard is a static page on GitHub Pages, so it cannot read the local
# calendar store. This runs on the Mac, reads today's events via EventKit, and
# upserts them into Supabase, where the dashboard reads them back.
#
# ── One-time setup ───────────────────────────────────────────────────────────
#   1. Put your dashboard password in the login Keychain. It stays on this Mac;
#      the script reads it at run time and it is never written to disk or logs:
#
#        security add-generic-password -a "azmerfaiesal@gmail.com" \
#          -s daily-dashboard-supabase -w
#
#      (the -w with no value prompts for the password without echoing it)
#
#   2. Run this once from Terminal and approve the calendar-access prompt:
#
#        ./tools/sync-apple-calendar.sh
#
#   3. Schedule it — see tools/com.azmer.calendar-sync.plist.
#
set -euo pipefail

SUPABASE_URL="https://pakfyyvdfwxglcjkatqz.supabase.co"
SUPABASE_KEY="sb_publishable_sC0C_y4pbJOUEANyk7o8Tg_u5PZpzVs"   # publishable key; RLS does the real work
ACCOUNT="${DASHBOARD_EMAIL:-azmerfaiesal@gmail.com}"
KEYCHAIN_SERVICE="daily-dashboard-supabase"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "calendar-sync: $*" >&2; exit 1; }

# ── 1. Credentials from the Keychain ─────────────────────────────────────────
PASSWORD="$(security find-generic-password -a "$ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)" \
  || die "no Keychain entry for $ACCOUNT / $KEYCHAIN_SERVICE — see the setup notes at the top of this file"

# ── 2. Exchange them for an access token ─────────────────────────────────────
# The password goes over stdin rather than argv or the environment, so it never
# shows up in `ps` output.
#
# rstrip("\n") matters: the `<<<` herestring appends a newline, and sending
# "password\n" is rejected as a bad credential with a bare HTTP 400.
AUTH_JSON="$(ACCOUNT="$ACCOUNT" python3 -c '
import json, os, sys
print(json.dumps({"email": os.environ["ACCOUNT"], "password": sys.stdin.read().rstrip("\n")}))
' <<<"$PASSWORD")"
unset PASSWORD

# Keep the body on failure so a wrong password is distinguishable from a bad request.
RESP="$(printf '%s' "$AUTH_JSON" | curl -sS -w $'\n%{http_code}' \
  "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_KEY" -H 'Content-Type: application/json' --data-binary @-)"
unset AUTH_JSON
CODE="$(tail -n1 <<<"$RESP")"
AUTH="$(sed '$d' <<<"$RESP")"

if [ "$CODE" != "200" ]; then
  REASON="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("error_description") or d.get("msg") or d.get("error") or "")
except Exception:
    print("")
' <<<"$AUTH")"
  die "sign-in failed (HTTP $CODE)${REASON:+: $REASON}"
fi

read -r TOKEN USER_ID <<<"$(python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["access_token"], d["user"]["id"])
' <<<"$AUTH")"
[ -n "$TOKEN" ] && [ -n "$USER_ID" ] || die "could not parse the auth response"

# ── 3. Read today'"'"'s events ───────────────────────────────────────────────────
EVENTS="$(osascript -l JavaScript "$HERE/read-today-events.js")" \
  || die "could not read the calendar"
case "$EVENTS" in
  *'"reason":"timeout"'*)
    die "calendar access prompt was not answered. Run this from Terminal while you are at the keyboard and click Allow, then the scheduled runs will inherit the grant." ;;
  *no-calendar-access*)
    die "calendar access denied — enable it in System Settings > Privacy & Security > Calendars (look for osascript or Terminal)" ;;
esac

TODAY="$(date +%F)"

# ── 4. Upsert, then clear anything cancelled ─────────────────────────────────
# Rows are stamped with user_id so RLS accepts them.
PAYLOAD="$(USER_ID="$USER_ID" python3 -c '
import json, os, sys
rows = json.load(sys.stdin)
for r in rows:
    r["user_id"] = os.environ["USER_ID"]
print(json.dumps(rows))
' <<<"$EVENTS")"

COUNT="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$PAYLOAD")"

if [ "$COUNT" -gt 0 ]; then
  curl -fsS -X POST "$SUPABASE_URL/rest/v1/calendar_events?on_conflict=id" \
    -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -H 'Prefer: resolution=merge-duplicates,return=minimal' \
    --data-binary "$PAYLOAD" >/dev/null || die "upsert failed"
fi

# Drop today's rows that are no longer in the calendar, so cancellations disappear
# instead of lingering forever.
KEEP="$(python3 -c '
import json, sys
ids = [r["id"] for r in json.load(sys.stdin)]
# PostgREST in.() list: quote each id so commas/spaces inside are safe.
print("(" + ",".join("\"" + i.replace("\"", "") + "\"" for i in ids) + ")" if ids else "")
' <<<"$PAYLOAD")"

DEL="$SUPABASE_URL/rest/v1/calendar_events?user_id=eq.$USER_ID&event_date=eq.$TODAY"
[ -n "$KEEP" ] && DEL="$DEL&id=not.in.$KEEP"
curl -fsS -X DELETE "$DEL" \
  -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $TOKEN" \
  -H 'Prefer: return=minimal' >/dev/null || die "cleanup failed"

echo "calendar-sync: $COUNT event(s) synced for $TODAY"
