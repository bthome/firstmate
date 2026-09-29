#!/usr/bin/env bash
# Live driver: real `claude -n <name>` (Claude Code 2.1.284) in an isolated
# Herdr fm-lab-* session; reads the composer through the real herdr backend
# with the change's classifier and with the base commit's classifier, then
# drives the away-mode inject_msg against it.
set -u
ROOT=$1; E=$2; BASE=$3
cd "$ROOT"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-namedcl-$$"; export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
STATE="$LAB/state"; BASELIB=$(mktemp "${TMPDIR:-/tmp}/fm-base-composer.XXXXXX.sh")
git show "$BASE:bin/fm-composer-lib.sh" > "$BASELIB"
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; rm -rf "$LAB" "$BASELIB"; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "prepare failed"; exit 1; }
. "$ROOT/bin/fm-supervise-daemon.sh"
fm_backend_source herdr || exit 1
C=$(fm_backend_herdr_container_ensure "$ROOT") || exit 1
IDS=$(fm_backend_herdr_create_task "${C%%$'\t'*}" named-claude "$ROOT" "${C#*$'\t'}") || exit 1
read -r _T PANE <<<"$IDS"; TARGET="$SESSION:$PANE"
echo "# lab session=$SESSION pane=$PANE"
for _ in $(seq 1 60); do
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null | jq -e '.result.process_info|(.foreground_processes|length==1) and (.foreground_processes[0].pid==.shell_pid)' >/dev/null 2>&1 && break; sleep 0.2; done
sleep 1
fm_backend_herdr_send_text_line "$TARGET" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' claude -n Andrew" || exit 1
screen() { fm_backend_herdr_cli "$SESSION" pane read "$PANE" --source visible 2>/dev/null; }
cstate() { fm_backend_composer_state herdr "$TARGET" 2>/dev/null; }
base_cstate() { ( . "$BASELIB"; fm_backend_composer_state herdr "$TARGET" 2>/dev/null ); }
for i in $(seq 1 90); do
  s=$(screen)
  if printf '%s' "$s" | grep -q 'trust this folder'; then echo "# accepting Claude folder-trust dialog for the gate worktree"; fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" down >/dev/null 2>&1; sleep 0.5; fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" enter >/dev/null 2>&1; sleep 3; continue; fi
  printf '%s' "$s" | grep -q -- '─ Andrew ─' && break
  sleep 1
done
sleep 4
echo "== S1 idle named claude visible screen (tail) =="; screen | grep -v '^[[:space:]]*$' | tail -8
echo "== S1 verdict with change: $(cstate)"
echo "== S1 verdict with base  : $(base_cstate)"
afk_enter "$STATE"
echo "== S3 base inject_msg on idle named claude =="
( . "$BASELIB"; LOG="$E/inject-base.log" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" inject_msg "lab ping: reply with just the word ok" "$STATE"; echo "rc=$?" ); cat "$E/inject-base.log" 2>/dev/null
# S2 typed text
fm_backend_herdr_cli "$SESSION" pane send-text "$PANE" "fix the login bug" >/dev/null 2>&1; sleep 2
echo "== S2 typed screen tail =="; screen | grep -v '^[[:space:]]*$' | tail -6
echo "== S2 verdict with change: $(cstate)"
echo "== S4 inject_msg over typed draft =="
LOG="$E/inject-pending.log" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" inject_msg "lab ping: reply with just the word ok" "$STATE"; echo "rc=$?"; cat "$E/inject-pending.log"
echo "== screen after deferred inject (draft untouched?) =="; screen | grep -v '^[[:space:]]*$' | tail -4
fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+u >/dev/null 2>&1; sleep 1
for k in 1 2 3; do [ "$(cstate)" = empty ] && break; fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+u >/dev/null 2>&1; sleep 1; done
echo "== after clearing, verdict: $(cstate)"
echo "== S3 change inject_msg on idle named claude =="
LOG="$E/inject-change.log" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" FM_INJECT_CONFIRM_RETRIES=6 FM_INJECT_CONFIRM_SLEEP=1 inject_msg "lab ping: reply with just the word ok" "$STATE"; echo "rc=$? last_failure=${INJECT_LAST_FAILURE:-none}"; cat "$E/inject-change.log" 2>/dev/null
sleep 12
echo "== screen after inject =="; screen | grep -v '^[[:space:]]*$' | tail -14
# S5 dead shell: exit claude
fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+c >/dev/null 2>&1; sleep 0.5; fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+c >/dev/null 2>&1; sleep 4
echo "== S5 shell screen tail =="; screen | grep -v '^[[:space:]]*$' | tail -4
echo "== S5 full screen =="; screen | cat -A | tail -12
echo "== S5 verdict with change: $(cstate)"; echo "== S5 verdict with base: $(base_cstate)"
echo "== S5 base inject_msg (on dead shell) =="; ( . "$BASELIB"; LOG="$E/inject-unknown-base.log" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" inject_msg "lab_ping_base" "$STATE"; echo "rc=$?" ); cat "$E/inject-unknown-base.log" 2>/dev/null
LOG="$E/inject-unknown.log" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" inject_msg "lab_ping_change" "$STATE"; echo "rc=$? last_failure=${INJECT_LAST_FAILURE:-none}"; cat "$E/inject-unknown.log" 2>/dev/null
afk_exit "$STATE" 2>/dev/null
