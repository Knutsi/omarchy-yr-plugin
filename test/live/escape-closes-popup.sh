#!/usr/bin/env bash
# Live check against the running Omarchy shell: open the Yr popup, press
# Escape, and see whether it goes away. Nothing is simulated — the shell's IPC
# summons the popup, wtype presses a real Escape, and the compositor's list of
# layer surfaces says whether it closed — so this tests the plugin the shell
# has loaded from ~/.config/omarchy/plugins/io.github.knutsi.yr.
#
#   test/live/escape-closes-popup.sh [--restart]
#
#   --restart  restart the shell first (`omarchy restart shell`)
#
#   exit 0  Escape closed the popup
#   exit 1  it did not — the bug; the popup is left open so you can see it
#   exit 2  could not run the check
#
# To see a bug and its fix, check out each commit in the installed copy and
# run with --restart:
#
#   git -C ~/.config/omarchy/plugins/io.github.knutsi.yr checkout --detach <commit>
#   test/live/escape-closes-popup.sh --restart
#
# The restart is what makes the check honest. The shell notices changed plugin
# files and rebuilds the widget (which clears a stuck popup), but the rebuilt
# widget keeps running the Panel.qml it compiled before, so without a restart
# this would test the old code under the new version number.
#
# It holds the keyboard for about a second.
set -u

ID=io.github.knutsi.yr
SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"

die() { echo "cannot run: $*" >&2; exit 2; }
ipc() { omarchy-shell "$@"; }
# A keyboard panel (the Yr popup is one) maps a layer surface with this
# namespace on its output while it is open or fading out.
popups() { hyprctl layers -j | jq '[.. | objects | select(.namespace? == "omarchy-keyboard-panel")] | length'; }
plugin_errors() { quickshell log -p "$SHELL_DIR" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep "plugins/$ID/.*Error"; }

restart=false
case "${1:-}" in
  "") ;;
  --restart) restart=true ;;
  *) die "unknown option $1 (usage: $0 [--restart])" ;;
esac

for tool in omarchy-shell quickshell hyprctl jq wtype; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
if $restart; then
  omarchy restart shell >/dev/null || die "omarchy restart shell failed"
fi
[ "$(ipc shell ping 2>/dev/null)" = ok ] || die "the Omarchy shell is not running"
enabled=$(ipc shell listPlugins | jq -r --arg id "$ID" '.[] | select(.id == $id) | .enabled')
[ "$enabled" = true ] || die "$ID is not installed and enabled"
[ "$(popups)" = 0 ] || die "a popup is already open. Close it first; if Escape, a click outside and \`omarchy-shell shell hide $ID\` all fail, that is this bug — rerun with --restart"

echo "$ID $(jq -r .version "$PLUGIN_DIR/manifest.json") at $(git -C "$PLUGIN_DIR" describe --always --dirty 2>/dev/null || echo "unknown commit")"
errors_before=$(plugin_errors | wc -l)

# Right after a restart the pill and its popup take a few seconds to load;
# until then a summon does nothing, so keep asking until the popup maps.
for _ in $(seq 30); do
  ipc shell summon "$ID" '{}' >/dev/null
  sleep 0.5
  [ "$(popups)" = 1 ] && break
done
[ "$(popups)" = 1 ] || die "the popup did not open — is the Yr pill on the bar?"

wtype -k Escape
sleep 0.5   # the fade-out is 140 ms
if [ "$(popups)" = 0 ]; then
  echo "PASS: Escape closed the popup"
  exit 0
fi

# Still open. Try the IPC close as well, to tell "Escape never reached the
# popup" apart from "nothing can close it".
ipc shell hide "$ID" >/dev/null
sleep 0.5
if [ "$(popups)" = 0 ]; then
  echo "FAIL: Escape did not close the popup; omarchy-shell shell hide did"
else
  echo "FAIL: the popup is stuck — neither Escape nor omarchy-shell shell hide closed it"
fi
plugin_errors | tail -n +"$((errors_before + 1))" | sed 's/^ *[A-Z]* *[a-z]*: /  /'
exit 1
