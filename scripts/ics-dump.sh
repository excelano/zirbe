#!/usr/bin/env bash
# Dump the calendar parts of recent messages from your own mailbox as parser
# fixtures, into ics-dump/ at the repo root (git-ignored). Wraps the ics-dump
# command in Packages/ZirbeMail.
#
# The address and server are asked for once and remembered in
# ~/.config/zirbe/ics-dump.env, outside the repo. The password is never stored:
# it is prompted for on every run, without echo, and handed to the command
# through the environment only.
#
#   scripts/ics-dump.sh          the newest 200 messages of INBOX
#   scripts/ics-dump.sh 500      a deeper window
#   scripts/ics-dump.sh --reset  forget the remembered address and server

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/zirbe"
config="$config_dir/ics-dump.env"
limit=200

for arg in "$@"; do
  case "$arg" in
    --reset) rm -f "$config"; echo "forgot the remembered settings" ;;
    ''|*[!0-9]*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) limit="$arg" ;;
  esac
done

# The app's provider table, mirrored: a known domain maps to its IMAP host,
# anything else suggests imap.<domain>, which the prompt lets you correct.
suggest_host() {
  local domain="${1##*@}"
  case "$domain" in
    icloud.com|me.com|mac.com) echo "imap.mail.me.com" ;;
    fastmail.com|fastmail.fm) echo "imap.fastmail.com" ;;
    gmail.com|googlemail.com) echo "imap.gmail.com" ;;
    yahoo.com|ymail.com|rocketmail.com) echo "imap.mail.yahoo.com" ;;
    aol.com) echo "imap.aol.com" ;;
    outlook.com|hotmail.com|live.com|msn.com|office365.com) echo "outlook.office365.com" ;;
    *) echo "imap.$domain" ;;
  esac
}

IMAP_USER=""; IMAP_HOST=""; IMAP_PORT=993; IMAP_MAILBOX=INBOX
if [[ -f "$config" ]]; then
  # shellcheck disable=SC1090
  source "$config"
fi

if [[ -z "$IMAP_USER" ]]; then
  read -r -p "Email address: " IMAP_USER
  [[ -n "$IMAP_USER" ]] || { echo "an address is required" >&2; exit 2; }
fi
if [[ -z "$IMAP_HOST" ]]; then
  suggested="$(suggest_host "$IMAP_USER")"
  read -r -p "IMAP server [$suggested]: " IMAP_HOST
  IMAP_HOST="${IMAP_HOST:-$suggested}"
  read -r -p "IMAP port [993]: " entered_port
  IMAP_PORT="${entered_port:-993}"
  mkdir -p "$config_dir"
  printf 'IMAP_USER=%q\nIMAP_HOST=%q\nIMAP_PORT=%q\nIMAP_MAILBOX=%q\n' "$IMAP_USER" "$IMAP_HOST" "$IMAP_PORT" "$IMAP_MAILBOX" > "$config"
  chmod 600 "$config"
  echo "remembered in $config (no password there)"
fi

read -r -s -p "Password for $IMAP_USER on $IMAP_HOST: " IMAP_PASS
echo
[[ -n "$IMAP_PASS" ]] || { echo "a password is required" >&2; exit 2; }

export IMAP_USER IMAP_HOST IMAP_PORT IMAP_MAILBOX IMAP_PASS
export IMAP_LIMIT="$limit"
export ICS_OUT="$root/ics-dump"

echo "== scanning the newest $limit messages in $IMAP_MAILBOX"
(cd "$root/Packages/ZirbeMail" && swift run ics-dump)
echo "== files are in $ICS_OUT; check names in CN= and descriptions before moving any into Tests"
