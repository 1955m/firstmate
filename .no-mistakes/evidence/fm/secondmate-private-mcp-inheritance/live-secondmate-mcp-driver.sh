#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh plus pi-mcp-adapter exclusive load.
# Isolated homes; recording tmux captures the launch command spawn types.
set -euo pipefail

ROOT=/Users/u/.no-mistakes/worktrees/2fdd8f23a65a/01M2SWT2HXR9NMWC6VG08B3AGH
EVIDENCE=/Users/u/.no-mistakes/evidence/01M2SWT2HXR9NMWC6VG08B3AGH
ADAPTER=/Users/u/.pi/agent/npm/node_modules/pi-mcp-adapter/dist/config.js

# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"

OUT="$EVIDENCE/live-secondmate-mcp-results.txt"
: > "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT"; }
fail_live() { log "FAIL: $*"; exit 1; }

TMP_ROOT=$(fm_test_tmproot live-secondmate-mcp)
log "tmp_root=$TMP_ROOT"

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
  exit 0
fi
if [ -n "${FM_FAKE_PI_ENV_LOG:-}" ]; then
  {
    printf 'PI_MCP_CONFIG_MODE=%s\n' "${PI_MCP_CONFIG_MODE:-}"
    printf 'argv=%s\n' "$*"
  } >> "$FM_FAKE_PI_ENV_LOG"
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

write_domain_mcp() {
  local dest=$1 server=$2
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "{\"mcpServers\":{\"$server\":{\"command\":\"true\"}}}" > "$dest"
  chmod 0600 "$dest"
}

mcp_real_path() {
  local home=$1
  printf '%s/mcp.json\n' "$(CDPATH='' cd -- "$home/.pi" && pwd -P)"
}

setup_case() {
  local name=$1 harness=$2 id=$3
  local case_dir home proj wt fakebin
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

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_WINDOWS_FILE="${FM_FAKE_WINDOWS_FILE:-}" \
    FM_FAKE_ENDPOINT_CREATED="${FM_FAKE_ENDPOINT_CREATED:-}" \
    FM_FAKE_LIST_CREATED_WINDOWS="${FM_FAKE_LIST_CREATED_WINDOWS:-}" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

dump_loaded_servers() {
  node --input-type=module - <<JS
import { loadMcpConfig } from $(printf '%s' "$(node -p 'JSON.stringify(process.argv[1])' "$ADAPTER")");
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const exclusive = process.env.LIVE_EXCLUSIVE === '1';
const mcpPath = process.env.LIVE_MCP_PATH;
const cwd = process.env.LIVE_CWD;
const decoyHome = process.env.LIVE_DECOY_HOME;
const decoyProject = process.env.LIVE_DECOY_PROJECT;

if (decoyHome) {
  process.env.HOME = decoyHome;
  process.env.PI_CODING_AGENT_DIR = join(decoyHome, '.pi', 'agent');
  mkdirSync(join(decoyHome, '.pi', 'agent'), { recursive: true });
  mkdirSync(join(decoyHome, '.config', 'mcp'), { recursive: true });
  writeFileSync(join(decoyHome, '.pi', 'agent', 'mcp.json'), JSON.stringify({
    mcpServers: { 'leaked-global': { command: 'true' }, 'mcp-atlassian': { command: 'true' } }
  }));
  writeFileSync(join(decoyHome, '.config', 'mcp', 'mcp.json'), JSON.stringify({
    mcpServers: { 'leaked-xdg': { command: 'true' } }
  }));
}
if (decoyProject) {
  mkdirSync(decoyProject, { recursive: true });
  mkdirSync(join(decoyProject, '.pi'), { recursive: true });
  writeFileSync(join(decoyProject, '.mcp.json'), JSON.stringify({
    mcpServers: { 'leaked-project': { command: 'true' }, 'mcp-atlassian': { command: 'true' } }
  }));
  writeFileSync(join(decoyProject, '.pi', 'mcp.json'), JSON.stringify({
    mcpServers: { 'leaked-project-pi': { command: 'true' } }
  }));
}
if (exclusive) process.env.PI_MCP_CONFIG_MODE = 'exclusive';
else delete process.env.PI_MCP_CONFIG_MODE;

const cfg = loadMcpConfig(mcpPath || undefined, cwd || process.cwd());
const names = Object.keys(cfg.mcpServers).sort();
process.stdout.write(JSON.stringify({ exclusive, mcpPath: mcpPath || null, servers: names }) + '\n');
JS
}

# ---------- Scenario 1: Figma worker inherits figma-console ----------
id='figma-worker-z1'
IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<<"$(setup_case figma-inherit pi "$id")"
printf 'figma-sm\n' > "$HOME_DIR/.fm-secondmate-home"
write_domain_mcp "$HOME_DIR/.pi/mcp.json" figma-console
write_domain_mcp "$CASE_DIR/other-home/.pi/mcp.json" mcp-atlassian
printf 'jira-sm\n' > "$CASE_DIR/other-home/.fm-secondmate-home"
mcp_figma=$(mcp_real_path "$HOME_DIR")
mcp_jira=$(mcp_real_path "$CASE_DIR/other-home")
launchlog="$CASE_DIR/launch.log"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
  "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off) || fail_live "figma spawn failed: $out"
launch=$(cat "$launchlog")
printf '%s\n' "$launch" > "$EVIDENCE/figma-worker-launch.txt"
printf '%s\n' "$out" > "$EVIDENCE/figma-worker-spawn-out.txt"
log "=== FIGMA WORKER SPAWN ==="
log "$out"
log "launch=$launch"
[[ "$out" == *"spawned $id harness=pi kind=ship"* ]] || fail_live "figma spawn identity"
[[ "$launch" == *"PI_MCP_CONFIG_MODE=exclusive "* ]] || fail_live "figma exclusive mode missing"
[[ "$launch" == *"--mcp-config '$mcp_figma'"* ]] || fail_live "figma launch did not pass home mcp: $mcp_figma"
[[ "$launch" != *"$mcp_jira"* ]] || fail_live "figma launch leaked jira mcp path"
[[ "$launch" != *"$WT_DIR/.pi/mcp.json"* ]] || fail_live "figma launch pointed at worktree mcp"
[[ -f "$HOME_DIR/.pi/mcp.json" ]] || fail_live "figma mcp disappeared from home"
[[ ! -e "$WT_DIR/.pi/mcp.json" ]] || fail_live "spawn copied mcp into the project worktree"
log "PASS figma worker inherits figma-console file in exclusive mode"

# Execute the constructed launch against the recording pi probe
envlog="$CASE_DIR/pi-env.log"
: > "$envlog"
PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_PI_ENV_LOG="$envlog" bash -c "$launch" || fail_live "figma launch command did not execute"
childenv=$(cat "$envlog")
printf '%s\n' "$childenv" > "$EVIDENCE/figma-worker-childenv.txt"
[[ "$childenv" == *"PI_MCP_CONFIG_MODE=exclusive"* ]] || fail_live "pi child missed exclusive mode"
[[ "$childenv" == *"--mcp-config $mcp_figma"* ]] || fail_live "pi child missed mcp path"
log "PASS figma worker child argv/env received exclusive mcp-config"

# Adapter exclusive load with adversarial decoys
decoy_home="$CASE_DIR/decoy-user"
loaded=$(LIVE_EXCLUSIVE=1 LIVE_MCP_PATH="$mcp_figma" LIVE_CWD="$CASE_DIR/decoy-project" \
  LIVE_DECOY_HOME="$decoy_home" LIVE_DECOY_PROJECT="$CASE_DIR/decoy-project" \
  HOME="$decoy_home" PI_CODING_AGENT_DIR="$decoy_home/.pi/agent" \
  dump_loaded_servers)
printf '%s\n' "$loaded" > "$EVIDENCE/figma-exclusive-loaded.json"
log "figma exclusive load=$loaded"
echo "$loaded" | grep -q '"figma-console"' || fail_live "exclusive load missing figma-console"
echo "$loaded" | grep -q 'mcp-atlassian' && fail_live "exclusive load leaked mcp-atlassian"
echo "$loaded" | grep -q 'leaked-' && fail_live "exclusive load leaked decoy servers"
log "PASS exclusive load of figma worker flags keeps only figma-console"

# ---------- Scenario 2: Jira second mate gets the same scoped inheritance ----------
id='jira-worker-z2'
IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<<"$(setup_case jira-inherit pi "$id")"
printf 'jira-sm\n' > "$HOME_DIR/.fm-secondmate-home"
write_domain_mcp "$HOME_DIR/.pi/mcp.json" mcp-atlassian
mcp_jira=$(mcp_real_path "$HOME_DIR")
launchlog="$CASE_DIR/launch.log"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
  "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off) || fail_live "jira spawn failed: $out"
launch=$(cat "$launchlog")
printf '%s\n' "$launch" > "$EVIDENCE/jira-worker-launch.txt"
log "=== JIRA WORKER SPAWN ==="
log "$out"
[[ "$launch" == *"PI_MCP_CONFIG_MODE=exclusive "* ]] || fail_live "jira exclusive mode missing"
[[ "$launch" == *"--mcp-config '$mcp_jira'"* ]] || fail_live "jira launch did not pass home mcp"
[[ "$launch" != *"figma-console"* ]] || fail_live "jira launch mentioned figma-console"
loaded=$(LIVE_EXCLUSIVE=1 LIVE_MCP_PATH="$mcp_jira" LIVE_CWD="$CASE_DIR/decoy-project" \
  LIVE_DECOY_HOME="$CASE_DIR/decoy-user" LIVE_DECOY_PROJECT="$CASE_DIR/decoy-project" \
  HOME="$CASE_DIR/decoy-user" PI_CODING_AGENT_DIR="$CASE_DIR/decoy-user/.pi/agent" \
  dump_loaded_servers)
printf '%s\n' "$loaded" > "$EVIDENCE/jira-exclusive-loaded.json"
log "jira exclusive load=$loaded"
echo "$loaded" | grep -q '"mcp-atlassian"' || fail_live "exclusive load missing mcp-atlassian"
echo "$loaded" | grep -q 'figma-console' && fail_live "jira exclusive load leaked figma-console"
echo "$loaded" | grep -q 'leaked-' && fail_live "jira exclusive load leaked decoy servers"
log "PASS jira second-mate workers inherit mcp-atlassian only"

# ---------- Scenario 3: primary does not inherit another domain's MCP ----------
id='primary-worker-z3'
IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<<"$(setup_case primary-noinherit pi "$id")"
write_domain_mcp "$HOME_DIR/.pi/mcp.json" figma-console
launchlog="$CASE_DIR/launch.log"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
  "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off) || fail_live "primary spawn failed: $out"
launch=$(cat "$launchlog")
printf '%s\n' "$launch" > "$EVIDENCE/primary-worker-launch.txt"
log "=== PRIMARY WORKER SPAWN ==="
log "$out"
[[ "$launch" != *"PI_MCP_CONFIG_MODE="* ]] || fail_live "primary opted into exclusive"
[[ "$launch" != *"--mcp-config"* ]] || fail_live "primary passed --mcp-config"
log "PASS primary workers do not inherit second-mate private MCP"

# ---------- Scenario 4: adversarial non-Pi Figma worker is refused ----------
id='figma-claude-z4'
IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<<"$(setup_case figma-claude claude "$id")"
printf 'figma-sm\n' > "$HOME_DIR/.fm-secondmate-home"
write_domain_mcp "$HOME_DIR/.pi/mcp.json" figma-console
launchlog="$CASE_DIR/launch.log"
endpoint="$CASE_DIR/endpoint.created"
set +e
out=$(FM_FAKE_ENDPOINT_CREATED="$endpoint" \
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
  "$id" "$PROJ_DIR" --harness claude --mode no-mistakes --yolo off 2>&1)
status=$?
set -e
printf '%s\n' "$out" > "$EVIDENCE/figma-claude-refusal.txt"
log "=== FIGMA CLAUDE REFUSAL ==="
log "status=$status"
log "$out"
[ "$status" -eq 1 ] || fail_live "claude spawn should refuse, got $status"
[[ "$out" == *"cannot be inherited by harness 'claude'"* ]] || fail_live "refusal did not name claude"
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail_live "refusal wrote task metadata"
[ ! -s "$launchlog" ] || fail_live "refusal typed a launch command"
[ ! -e "$endpoint" ] || fail_live "refusal created an endpoint"
log "PASS non-Pi Figma worker refused before mutation"

# ---------- Scenario 5: scout from Figma home also inherits ----------
id='figma-scout-z5'
IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<<"$(setup_case figma-scout pi "$id")"
printf 'figma-sm\n' > "$HOME_DIR/.fm-secondmate-home"
write_domain_mcp "$HOME_DIR/.pi/mcp.json" figma-console
mcp_figma=$(mcp_real_path "$HOME_DIR")
launchlog="$CASE_DIR/launch.log"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$launchlog" \
  "$id" "$PROJ_DIR" --harness pi --scout) || fail_live "figma scout spawn failed: $out"
launch=$(cat "$launchlog")
printf '%s\n' "$launch" > "$EVIDENCE/figma-scout-launch.txt"
log "=== FIGMA SCOUT SPAWN ==="
log "$out"
[[ "$out" == *"spawned $id harness=pi kind=scout"* ]] || fail_live "scout identity"
[[ "$launch" == *"PI_MCP_CONFIG_MODE=exclusive "* ]] || fail_live "scout exclusive missing"
[[ "$launch" == *"--mcp-config '$mcp_figma'"* ]] || fail_live "scout did not pass home mcp"
log "PASS figma scout inherits private figma MCP"

log "ALL LIVE SCENARIOS PASSED"
