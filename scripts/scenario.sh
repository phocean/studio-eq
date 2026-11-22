#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Jean-Christophe Baptiste
# Automated switching scenarios against the running app, using a temporary aggregate device
# as a stand-in for a second output / for the Studio Display being plugged and unplugged.
# Run it with `make scenario`, which builds the validation app (the only one that honours
# -TargetDeviceUID), the audioctl helper and a test tone, then calls:
#   scripts/scenario.sh <path/to/StudioEQ.app> <test-audio-file>
set -u
APP=$1; AUDIO=$2; CTL=build/audioctl; FAKE=test.fake.output
[[ -x $CTL ]] || { echo "missing $CTL (see header)" >&2; exit 1; }
# Selected output's UID (UIDs may contain spaces: strip the marker and the trailing rate).
out() { $CTL list | grep '^\*' | sed -E 's/^\* //; s/ [0-9.]+$//'; }
ORIGINAL_OUTPUT=$(out)
# Whatever happens (end, error, Ctrl-C): stop the player and the test instance, and give the
# user their output back.
cleanup() { kill ${PLAYER:-} 2>/dev/null; pkill -x StudioEQ; [[ -n $ORIGINAL_OUTPUT ]] && $CTL default "$ORIGINAL_OUTPUT" >/dev/null; }
trap cleanup EXIT INT TERM
since() { date "+%Y-%m-%d %H:%M:%S"; }
st() { /usr/bin/log show --start "$APPSTART" --info --style compact --predicate 'subsystem == "com.jcbaptiste.StudioEQ" AND eventMessage BEGINSWITH "status:"' 2>/dev/null | grep -o 'status: [a-zA-Z]*' | tail -1; }
step() { echo "\n## $1"; }
expect() { local got; got=$(st); [[ "$got" == "status: $1" ]] && echo "  PASS  $got (output: $(out))" || echo "  FAIL  expected $1, got '$got' (output: $(out))"; }
start_app() { pkill -x StudioEQ; sleep 1; APPSTART=$(since); open -n "$APP" --args -TargetDeviceUID "$1"; sleep 2; }
$CTL default BuiltInSpeakerDevice >/dev/null
afplay -v 0.3 "$AUDIO" & PLAYER=$!

echo "# Part A — target = built-in speakers, a second output appears and is selected"
start_app BuiltInSpeakerDevice; expect active
step "second output appears";            ($CTL fake $FAKE 12 >/dev/null &); sleep 1.5; expect active
step "second output selected";           $CTL default $FAKE >/dev/null; sleep 1; expect otherOutput
step "back to target";                   $CTL default BuiltInSpeakerDevice >/dev/null; sleep 1; expect active
step "select other then it disappears";  $CTL default $FAKE >/dev/null; sleep 10; expect active

echo "\n# Part B — target = simulated Studio Display (temporary device)"
start_app $FAKE; expect noDisplay
# macOS may re-select a returning device on its own (as it does for a Studio Display): the
# expected state follows whichever output is actually selected.
step "display plugged";                  ($CTL fake $FAKE 8 >/dev/null &); sleep 1.5; [[ $(out) == $FAKE ]] && expect active || expect otherOutput
step "display selected";                 $CTL default $FAKE >/dev/null; sleep 1.5; expect active
step "display unplugged while active";   sleep 6; expect noDisplay
step "display re-plugged and selected";  ($CTL fake $FAKE 5 >/dev/null &); sleep 1; $CTL default $FAKE >/dev/null; sleep 1.5; expect active
sleep 4
