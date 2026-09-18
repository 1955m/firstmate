#!/usr/bin/env bash
# Behavior tests for second-mate private MCP inheritance at spawn.
#
# A seeded second-mate home with a safe .pi/mcp.json must pass that exact file
# to Pi and Pi-signed ship/scout workers, including relaunches, in exclusive
# config mode. Primary homes, unrelated homes, and homes without the file must
# not inherit. Unsafe files and non-Pi harnesses must refuse before mutation.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-mcp)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

install_mcp_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_LIST_CREATED_WINDOWS:-}" = 1 ] && [ -n "${FM_FAKE_WINDOWS_FILE:-}" ] && [ -f "$FM_FAKE_WINDOWS_FILE" ]; then
      cat "$FM_FAKE_WINDOWS_FILE"
    fi
    exit 0
    ;;
  has-session|new-session|kill-window|set-window-option) exit 0 ;;
  new-window)
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=$2; shift 2 ;;
        -F|-t|-c) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_WINDOWS_FILE:-}" ] && [ -n "$name" ]; then
      printf '%s\n' "$name" >> "$FM_FAKE_WINDOWS_FILE"
    fi
    if [ -n "${FM_FAKE_ENDPOINT_CREATED:-}" ]; then
      : > "$FM_FAKE_ENDPOINT_CREATED"
    fi
    printf '@1\n'
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

make_mcp_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  install_mcp_tmux "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

write_safe_mcp() {
  local dest=$1
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' '{"mcpServers":{}}' > "$dest"
  chmod 0600 "$dest"
}

mark_secondmate_home() {
  local home=$1 id=$2
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

mcp_real_path() {
  local home=$1
  printf '%s/mcp.json\n' "$(CDPATH='' cd -- "$home/.pi" && pwd -P)"
}

make_mcp_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_mcp_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_mcp_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_mcp_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR= \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_WINDOWS_FILE="${FM_FAKE_WINDOWS_FILE:-}" \
    FM_FAKE_ENDPOINT_CREATED="${FM_FAKE_ENDPOINT_CREATED:-}" \
    FM_FAKE_LIST_CREATED_WINDOWS="${FM_FAKE_LIST_CREATED_WINDOWS:-}" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

assert_no_spawn_mutation() {
  local home=$1 id=$2 launchlog=$3 endpoint=$4
  assert_absent "$home/state/$id.meta" "unsafe or non-Pi refusal wrote task metadata"
  assert_absent "$home/data/$id/launch-brief.md" "refusal rendered a launch brief"
  [ ! -s "$launchlog" ] || fail "refusal typed a launch command"
  [ ! -e "$endpoint" ] || fail "refusal created an endpoint"
}

test_scoped_pi_worker_inheritance() {
  local rec id out status launch mcp decoy harness kind
  for harness in pi pi-signed; do
    for kind in ship scout; do
      id="mcp-inherit-${harness}-${kind}-z1"
      rec=$(make_mcp_case "inherit-$harness-$kind" "$harness" "$id")
      read_mcp_case "$rec"
      mark_secondmate_home "$HOME_DIR" mcp-sm
      write_safe_mcp "$HOME_DIR/.pi/mcp.json"
      decoy=$WT_DIR/.pi/mcp.json
      mcp=$(mcp_real_path "$HOME_DIR")
      launchlog="$CASE_DIR/launch.log"
      if [ "$kind" = ship ]; then
        out=$(run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
          "$id" "$PROJ_DIR" --harness "$harness" --mode no-mistakes --yolo off)
      else
        out=$(run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
          "$id" "$PROJ_DIR" --harness "$harness" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$harness $kind inheritance spawn should succeed"$'\n'"$out"
      launch=$(cat "$launchlog")
      assert_contains "$launch" "PI_MCP_CONFIG_MODE=exclusive " \
        "$harness $kind launch must opt into Pi exclusive-config mode"
      assert_contains "$launch" "--mcp-config $(printf "'%s'" "$mcp")" \
        "$harness $kind launch must pass the parent home MCP file"
      assert_not_contains "$launch" "$decoy" \
        "$harness $kind launch must not point at a worktree MCP file"
      assert_contains "$out" "spawned $id harness=$harness kind=$kind" \
        "$harness $kind spawn did not preserve identity"
    done
  done
  pass "seeded second-mate Pi workers inherit the home MCP in exclusive mode"
}

test_relaunch_inherits_private_mcp() {
  local rec id out status launch mcp launchlog windows
  id=mcp-relaunch-z2
  rec=$(make_mcp_case relaunch-pi pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  mcp=$(mcp_real_path "$HOME_DIR")
  launchlog="$CASE_DIR/launch.log"
  windows="$CASE_DIR/windows"
  : > "$windows"
  out=$(FM_FAKE_WINDOWS_FILE="$windows" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "initial spawn for relaunch coverage should succeed"$'\n'"$out"
  : > "$launchlog"
  out=$(FM_FAKE_WINDOWS_FILE="$windows" FM_FAKE_LIST_CREATED_WINDOWS=1 \
    FM_FAKE_PANE_COMMAND=zsh \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" --relaunch --harness pi)
  status=$?
  expect_code 0 "$status" "relaunch should succeed from a dead endpoint"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "PI_MCP_CONFIG_MODE=exclusive " \
    "relaunch must keep exclusive-config mode"
  assert_contains "$launch" "--mcp-config $(printf "'%s'" "$mcp")" \
    "relaunch must pass the same parent home MCP file"
  pass "worker relaunch inherits the second-mate private MCP"
}

test_primary_home_does_not_inherit() {
  local rec id out status launch launchlog
  id=mcp-primary-z3
  rec=$(make_mcp_case primary-no-inherit pi "$id")
  read_mcp_case "$rec"
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  launchlog="$CASE_DIR/launch.log"
  out=$(run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "primary spawn with a private MCP file should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_not_contains "$launch" "PI_MCP_CONFIG_MODE=" \
    "primary launch must not opt into exclusive-config mode"
  assert_not_contains "$launch" "--mcp-config" \
    "primary launch must not pass --mcp-config"
  pass "primary homes do not inherit merely because .pi/mcp.json exists"
}

test_unrelated_home_isolation() {
  local rec id out status launch mcp_a mcp_b other launchlog
  id=mcp-isolate-z4
  rec=$(make_mcp_case isolate-a pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-a
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  other="$CASE_DIR/other-home"
  mkdir -p "$other"
  mark_secondmate_home "$other" mcp-b
  write_safe_mcp "$other/.pi/mcp.json"
  mcp_a=$(mcp_real_path "$HOME_DIR")
  mcp_b=$(mcp_real_path "$other")
  launchlog="$CASE_DIR/launch.log"
  out=$(run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "home A spawn should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--mcp-config $(printf "'%s'" "$mcp_a")" \
    "worker from home A must receive home A's MCP file"
  assert_not_contains "$launch" "$mcp_b" \
    "worker from home A must not receive an unrelated home's MCP file"
  pass "unrelated second-mate homes cannot leak MCP config into each other's workers"
}

test_no_config_keeps_existing_launch() {
  local rec id out status launch launchlog
  id=mcp-noconfig-z5
  rec=$(make_mcp_case noconfig-sm pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  launchlog="$CASE_DIR/launch.log"
  out=$(run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "second-mate spawn without private MCP should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular -e" \
    "no-config second-mate Pi launch must keep the canonical worker shape"
  assert_not_contains "$launch" "PI_MCP_CONFIG_MODE=" \
    "no-config launch must not set exclusive-config mode"
  assert_not_contains "$launch" "--mcp-config" \
    "no-config launch must not pass --mcp-config"
  pass "second-mate homes without private MCP keep the existing worker launch"
}

test_unsafe_mcp_refuses_before_mutation() {
  local rec id out status launchlog endpoint outside
  id=mcp-unsafe-z6
  rec=$(make_mcp_case unsafe-symlink pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  mkdir -p "$HOME_DIR/.pi"
  ln -s /tmp/missing-mcp.json "$HOME_DIR/.pi/mcp.json"
  launchlog="$CASE_DIR/launch.log"
  endpoint="$CASE_DIR/endpoint.created"
  out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "symlink MCP must refuse"
  assert_contains "$out" "secondmate private MCP is a symlink" \
    "symlink refusal must name the unsafe file"
  assert_no_spawn_mutation "$HOME_DIR" "$id" "$launchlog" "$endpoint"

  rec=$(make_mcp_case unsafe-mode pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  chmod 0644 "$HOME_DIR/.pi/mcp.json"
  launchlog="$CASE_DIR/launch.log"
  endpoint="$CASE_DIR/endpoint.created"
  out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "mode 0644 MCP must refuse"
  assert_contains "$out" "secondmate private MCP must be mode 0600" \
    "mode refusal must name the required mode"
  assert_no_spawn_mutation "$HOME_DIR" "$id" "$launchlog" "$endpoint"

  rec=$(make_mcp_case unsafe-hardlink pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  ln "$HOME_DIR/.pi/mcp.json" "$CASE_DIR/mcp.alias"
  launchlog="$CASE_DIR/launch.log"
  endpoint="$CASE_DIR/endpoint.created"
  out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "hardlinked MCP must refuse"
  assert_contains "$out" "secondmate private MCP is not a single-link file" \
    "hardlink refusal must name the link-count requirement"
  assert_no_spawn_mutation "$HOME_DIR" "$id" "$launchlog" "$endpoint"

  rec=$(make_mcp_case unsafe-escape pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  outside="$CASE_DIR/escaped-home"
  write_safe_mcp "$outside/.pi/mcp.json"
  mkdir -p "$HOME_DIR"
  ln -s "$outside/.pi" "$HOME_DIR/.pi"
  launchlog="$CASE_DIR/launch.log"
  endpoint="$CASE_DIR/endpoint.created"
  out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "escaped MCP directory must refuse"
  assert_contains "$out" "secondmate private MCP directory is a symlink" \
    "path-escape refusal must name the symlink directory"
  assert_no_spawn_mutation "$HOME_DIR" "$id" "$launchlog" "$endpoint"
  [ -f "$outside/.pi/mcp.json" ] || fail "escape refusal must not delete the external MCP file"
  pass "unsafe private MCP refuses before endpoint, worktree, or task record mutation"
}

test_non_pi_refuses_when_inheritance_cannot_be_guaranteed() {
  local rec id out status launchlog endpoint
  id=mcp-nonpi-z7
  rec=$(make_mcp_case nonpi-claude claude "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  launchlog="$CASE_DIR/launch.log"
  endpoint="$CASE_DIR/endpoint.created"
  out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" --harness claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "claude must refuse when private MCP cannot be inherited"
  assert_contains "$out" "cannot be inherited by harness 'claude'" \
    "non-Pi refusal must name the selected harness"
  assert_no_spawn_mutation "$HOME_DIR" "$id" "$launchlog" "$endpoint"

  rec=$(make_mcp_case nonpi-raw pi "$id")
  read_mcp_case "$rec"
  mark_secondmate_home "$HOME_DIR" mcp-sm
  write_safe_mcp "$HOME_DIR/.pi/mcp.json"
  launchlog="$CASE_DIR/launch.log"
  endpoint="$CASE_DIR/endpoint.created"
  out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
    run_mcp_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
    "$id" "$PROJ_DIR" "custom-agent --flag" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a raw launch command must refuse when private MCP cannot be inherited"
  assert_contains "$out" "cannot be inherited by harness 'custom-agent'" \
    "raw-launch refusal must name the raw command"
  assert_no_spawn_mutation "$HOME_DIR" "$id" "$launchlog" "$endpoint"
  pass "non-Pi workers are refused rather than launched without required MCP capability"
}

test_scoped_pi_worker_inheritance
test_relaunch_inherits_private_mcp
test_primary_home_does_not_inherit
test_unrelated_home_isolation
test_no_config_keeps_existing_launch
test_unsafe_mcp_refuses_before_mutation
test_non_pi_refuses_when_inheritance_cannot_be_guaranteed

echo "# all fm-spawn-secondmate-mcp tests passed"
