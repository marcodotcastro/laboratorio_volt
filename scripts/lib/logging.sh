#!/usr/bin/env bash

set -euo pipefail

LOG_ROOT="${WORKSPACE_LOG_ROOT:-${WORKSPACE_STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.workspace}/logs}"
LOG_FILE=''
LOG_ISSUE_ID=''
LOG_ACTION=''
LOG_FINISHED=false
LOG_WRITE_EVENTS=true
LOG_EMIT_HUMAN=true
LOG_STARTED_AT=''
LOG_LAST_OUTPUT=''
LOG_LAST_HUMAN_LINE=''

_log_timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
_log_clock() { date '+%s.%N'; }

_log_duration() {
  awk -v started="$1" -v finished="$2" 'BEGIN {
    duration = finished - started
    if (duration < 0) duration = 0
    printf "%.6f", duration
  }'
}

_log_short_duration() {
  awk -v duration="$1" 'BEGIN { printf "%.2f", duration + 0 }'
}

_log_sensitive_name() {
  [[ "${1,,}" =~ (token|secret|password|passwd|credential|authorization|api[_-]?key|private[_-]?key|cookie) ]]
}

_log_redact_inline() {
  local text="$1" pattern match secret prefix replacement before after result=''
  local had_nocasematch=false
  if shopt -q nocasematch; then
    had_nocasematch=true
  else
    shopt -s nocasematch
  fi
  pattern='("?)([^[:space:]"=:,;{}]*)?(token|secret|password|passwd|credential|authorization|api[_-]?key|private[_-]?key|cookie)("?)[[:space:]]*[=:][[:space:]]*("[^"]*"|[^[:space:],;}]+)'
  while [[ "$text" =~ $pattern ]]; do
    match="${BASH_REMATCH[0]}"
    secret="${BASH_REMATCH[5]}"
    prefix="${match%"$secret"}"
    case "$secret" in
      '"'*'"') replacement='"[REDACTED]"' ;;
      *) replacement='[REDACTED]' ;;
    esac
    before="${text%%"$match"*}"
    after="${text#*"$match"}"
    if [[ "$secret" == '[REDACTED]' || "$secret" == '"[REDACTED]"' ]]; then
      result+="$before$match"
    else
      result+="$before$prefix$replacement"
    fi
    text="$after"
  done
  [ "$had_nocasematch" = true ] || shopt -u nocasematch
  printf '%s' "$result$text"
}

_redact_text() {
  local text="$1" name value
  while IFS= read -r name; do
    _log_sensitive_name "$name" || continue
    value="${!name-}"
    [ "${#value}" -ge 4 ] || continue
    text="${text//"$value"/[REDACTED]}"
  done < <(compgen -e)
  _log_redact_inline "$text"
}

_log_safe_arg() {
  local arg="$1" previous_name="${2:-}" name value
  if _log_sensitive_name "$previous_name"; then
    printf '[REDACTED]'
    return 0
  fi
  while IFS= read -r name; do
    _log_sensitive_name "$name" || continue
    value="${!name-}"
    [ "${#value}" -ge 4 ] || continue
    if [ "$arg" = "$value" ]; then
      printf '[REDACTED]'
      return 0
    fi
  done < <(compgen -e)
  _redact_text "$arg"
}

_log_action_slug() {
  local value="$1"
  value="${value,,}"
  case "$value" in
    synchronizing\ canonical\ skills) value='sync_skills' ;;
    fetching\ crm\ source\ repository) value='fetch_crm_source' ;;
    cloning\ crm\ source\ repository) value='clone_crm_source' ;;
    fetching\ all\ in\ one\ source\ repository) value='fetch_aio_source' ;;
    cloning\ all\ in\ one\ source\ repository) value='clone_aio_source' ;;
    registering\ workspace\ repository|adding\ workspace\ repository) value='register_workspace' ;;
    checking\ existing\ workspace\ coordinator|searching\ for\ the\ workspace\ coordinator\ in\ orca) value='find_coordinator' ;;
    creating\ workspace\ coordinator) value='create_coordinator' ;;
    renaming\ workspace\ coordinator\ branch) value='align_coordinator' ;;
    verifying\ workspace\ coordinator\ worktree) value='verify_coordinator' ;;
    rendering\ runtime\ environment) value='render_environment' ;;
    checking\ docker\ compose) value='check_compose' ;;
    starting\ runtime) value='start' ;;
    stopping\ runtime|stopping\ runtime\ for\ restart) value='stop' ;;
    restarting\ runtime) value='restart' ;;
    resetting\ runtime\ state) value='reset_state' ;;
    rebuilding\ runtime) value='rebuild' ;;
    destroying\ runtime\ state) value='destroy' ;;
    checking\ running\ services) value='check_services' ;;
    preparing\ local\ development\ account) value='prepare_account' ;;
    registering\ proxy\ route) value='register_proxy' ;;
    unregistering\ proxy\ route) value='unregister_proxy' ;;
    checking\ runtime\ endpoints) value='check_endpoints' ;;
    destroying\ issue\ docker\ state) value='clean_runtime' ;;
    creating\ crm\ backend|reusing\ crm\ backend) value='create_backend_worktree' ;;
    creating\ all\ in\ one\ frontend|reusing\ all\ in\ one\ frontend) value='create_frontend_worktree' ;;
    removing\ local\ crm\ backend\ worktree) value='remove_backend_worktree' ;;
    removing\ local\ all\ in\ one\ frontend\ worktree) value='remove_frontend_worktree' ;;
    inspecting\ orca\ coordinator*) value='inspect_coordinator' ;;
    removing\ orca\ coordinator*) value='remove_coordinator' ;;
  esac
  value="${value//[^a-z0-9]/_}"
  value="${value##_}"
  value="${value%%_}"
  printf '%s\n' "$value"
}

_log_human_suppressed() {
  local event="$1" details="$2"
  case "$event" in
    progress|success) ;;
    *) return 1 ;;
  esac
  case "$details" in
    *'"display":"audit"'*|*'"display": "audit"'*) return 0 ;;
    *) return 1 ;;
  esac
}

_run_logged_details() {
  case "$1" in
    audit) printf '{"display":"audit"}' ;;
    terminal) printf '{"display":"terminal"}' ;;
    *) printf '' ;;
  esac
}

_log_human_labels() {
  case "$1" in
    issue.prepare_crm_source) printf 'CRM\tpersistent source' ;;
    issue.prepare_frontend_source) printf 'All In One\tpersistent source' ;;
    issue.fetch_crm_source|issue.clone_crm_source) printf 'CRM\tpersistent source' ;;
    issue.fetch_aio_source|issue.clone_aio_source) printf 'All In One\tpersistent source' ;;
    issue.sync_skills) printf 'Workspace\tskills' ;;
    issue.register_workspace|issue.add_workspace) printf 'Workspace\trepository' ;;
    issue.find_coordinator|issue.create_coordinator|issue.align_coordinator|issue.verify_coordinator|destroy.remove_coordinator)
      printf 'Workspace\tcoordinator' ;;
    issue.create_backend_worktree|issue.reuse_backend_worktree|destroy.remove_backend_worktree) printf 'Backend\tissue worktree' ;;
    issue.create_frontend_worktree|issue.reuse_frontend_worktree|destroy.remove_frontend_worktree) printf 'Frontend\tissue worktree' ;;
    destroy.clean_runtime|runtime.destroy|runtime.reset_state) printf 'Runtime\tstate' ;;
    runtime.rebuild|runtime.start|runtime.restart|runtime.stop) printf 'Runtime\tcontainers' ;;
    runtime.check_compose) printf 'Runtime\tCompose' ;;
    runtime.check_services) printf 'Runtime\tservices' ;;
    runtime.prepare_account) printf 'Runtime\taccount' ;;
    runtime.register_proxy|runtime.unregister_proxy) printf 'Runtime\tproxy' ;;
    runtime.check_endpoints) printf 'Runtime\tendpoints' ;;
    destroy.preserve_state) printf 'Workspace\tissue state' ;;
    *) return 1 ;;
  esac
}

_log_human_message() {
  local event="$1" action="$2" details="${3:-}" duration="${4:-}" labels resource scope state outcome
  labels="$(_log_human_labels "$action")" || return 1
  IFS=$'\t' read -r resource scope <<< "$labels"
  case "$event" in
    progress) state='checking' ;;
    success) state='ready' ;;
    warning) state='warning' ;;
    error) state='failed' ;;
    *) return 1 ;;
  esac
  case "$action" in
    issue.prepare_crm_source|issue.prepare_frontend_source) [ "$event" = progress ] && state='updating' ;;
    issue.create_coordinator|issue.create_backend_worktree|issue.create_frontend_worktree)
      [ "$event" = progress ] && state='creating' ;;
    issue.reuse_backend_worktree|issue.reuse_frontend_worktree)
      [ "$event" = progress ] && state='reusing' ;;
    issue.align_coordinator) [ "$event" = progress ] && state='aligning' ;;
    destroy.clean_runtime|destroy.remove_backend_worktree|destroy.remove_frontend_worktree|destroy.remove_coordinator|runtime.destroy)
      [ "$event" = progress ] && state='removing' ;;
    destroy.preserve_state) [ "$event" = progress ] && state='preserving' ;;
    runtime.start) [ "$event" = progress ] && state='starting' ;;
    runtime.stop) [ "$event" = progress ] && state='stopping' ;;
    runtime.restart) [ "$event" = progress ] && state='restarting' ;;
    runtime.reset_state) [ "$event" = progress ] && state='resetting' ;;
    runtime.rebuild) [ "$event" = progress ] && state='rebuilding' ;;
    runtime.prepare_account) [ "$event" = progress ] && state='preparing' ;;
    runtime.register_proxy) [ "$event" = progress ] && state='registering' ;;
    runtime.unregister_proxy) [ "$event" = progress ] && state='removing' ;;
    runtime.check_endpoints|runtime.check_services|runtime.check_compose) : ;;
  esac
  if [ "$event" = success ]; then
    case "$action" in
      issue.prepare_crm_source|issue.prepare_frontend_source|issue.create_backend_worktree|issue.create_frontend_worktree|issue.create_coordinator)
        state='ready' ;;
      destroy.clean_runtime|destroy.remove_backend_worktree|destroy.remove_frontend_worktree|destroy.remove_coordinator|runtime.destroy)
        state='removed' ;;
      runtime.stop) state='stopped' ;;
      runtime.reset_state) state='reset' ;;
      issue.align_coordinator) state='aligned' ;;
    esac
    if [[ "$details" =~ \"outcome\"[[:space:]]*:[[:space:]]*\"([a-z]+)\" ]]; then
      outcome="${BASH_REMATCH[1]}"
      case "$outcome" in
        created|reused|updated|removed|skipped) state="$state · $outcome" ;;
      esac
    fi
  fi
  [ "$event" = progress ] || [ -z "$duration" ] || state="$state · $(_log_short_duration "$duration")s"
  printf '%s · %s · %s' "$resource" "$scope" "$state"
}

log_event() {
  local event="$1" action="$2" status="$3" message="$4" details="${5:-}" duration="${6:-}"
  local safe_message safe_details human_message marker human_line
  [ -n "${LOG_FILE:-}" ] || { printf 'ERROR: Logging has not started\n' >&2; return 1; }
  safe_message="$(_redact_text "$message")"
  safe_details="$(_redact_text "$details")"
  if [ "${LOG_WRITE_EVENTS:-true}" = true ]; then
    printf '[%s] event=%s action=%s status=%s message=%q' \
      "$(_log_timestamp)" "$event" "$action" "$status" "$safe_message" >> "$LOG_FILE"
    [ -z "$duration" ] || printf ' duration=%s' "$duration" >> "$LOG_FILE"
    [ -z "$safe_details" ] || printf ' details=%q' "$safe_details" >> "$LOG_FILE"
    printf '\n' >> "$LOG_FILE"
  fi
  if [ "${WORKSPACE_EVENT_STREAM:-false}" = true ]; then
    printf 'VDD_EVENT event=%s action=%s status=%s message=%q' \
      "$event" "$action" "$status" "$safe_message" >&2
    [ -z "$duration" ] || printf ' duration=%s' "$duration" >&2
    [ -z "$safe_details" ] || printf ' details=%q' "$safe_details" >&2
    printf '\n' >&2
  elif [ "${LOG_EMIT_HUMAN:-true}" = true ] && ! _log_human_suppressed "$event" "$details"; then
    human_message=''
    human_message="$(_log_human_message "$event" "$action" "$details" "$duration" 2>/dev/null || true)"
    case "$event" in
      progress) marker='→' ;;
      success) marker='✓' ;;
      warning) marker='!' ;;
      error) marker='✗' ;;
      finish)
        case "$status" in
          warning*) marker='!' ;;
          success|0) return 0 ;;
          *) marker='✗' ;;
        esac
        ;;
    esac
    [ -n "${marker:-}" ] || return 0
    [ -n "$human_message" ] && safe_message="$human_message"
    human_line="$marker $safe_message"
    [ "$human_line" = "$LOG_LAST_HUMAN_LINE" ] && return 0
    LOG_LAST_HUMAN_LINE="$human_line"
    printf '%s\n' "$human_line" >&2
  fi
}

_log_exit_trap() {
  local status="$1"
  if [ "${LOG_FINISHED:-false}" != true ] && [ -n "${LOG_FILE:-}" ]; then
    if [ "$status" -eq 0 ]; then
      _log_finish_file success
    else
      log_event error "${LOG_ACTION}.failure" error "Command failed (exit $status)" "{\"exit\":$status}"
      _log_finish_file "failed:$status"
    fi
  fi
  return "$status"
}

_log_finish_file() {
  local status="$1" message duration=''
  if [ "${WORKSPACE_LOG_FILE_EXTERNAL:-false}" = true ]; then
    LOG_FINISHED=true
    return 0
  fi
  if [[ "$status" == success ]]; then
    message='Command completed'
  else
    message="Command failed ($status)"
  fi
  if [ -n "${LOG_STARTED_AT:-}" ]; then
    duration="$(_log_duration "$LOG_STARTED_AT" "$(_log_clock)")"
  fi
  log_event finish "${LOG_ACTION}.finish" "$status" "$message" '' "$duration"
  LOG_FINISHED=true
}

start_log() {
  local issue_id="$1" action="$2" safe_action timestamp
  [[ "$issue_id" =~ ^CC-[1-9][0-9]*$ ]] || { printf 'ERROR: Invalid issue ID for log\n' >&2; return 1; }
  [ -n "$action" ] || { printf 'ERROR: Log action is required\n' >&2; return 1; }
  action="$(_redact_text "$action")"
  safe_action="${action//[^A-Za-z0-9_.-]/-}"
  if [ -n "${WORKSPACE_LOG_FILE:-}" ]; then
    [ -f "$WORKSPACE_LOG_FILE" ] || {
      printf 'ERROR: External log file does not exist\n' >&2
      return 1
    }
    LOG_FILE="$WORKSPACE_LOG_FILE"
    LOG_ISSUE_ID="$issue_id"
    LOG_ACTION="$action"
    LOG_FINISHED=false
    LOG_WRITE_EVENTS=true
    LOG_STARTED_AT="$(_log_clock)"
    LOG_LAST_HUMAN_LINE=''
    [ "${WORKSPACE_EVENT_STREAM:-false}" = true ] && LOG_WRITE_EVENTS=false
    trap '_log_exit_trap "$?"' EXIT
    return 0
  fi
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  LOG_ISSUE_ID="$issue_id"
  LOG_ACTION="$action"
  mkdir -p "$LOG_ROOT/$issue_id"
  LOG_FILE="$(mktemp "$LOG_ROOT/$issue_id/${timestamp}-${safe_action}.XXXXXX.log")" || {
    printf 'ERROR: Could not create log file\n' >&2
    return 1
  }
  chmod 600 "$LOG_FILE"
  LOG_FINISHED=false
  LOG_WRITE_EVENTS=true
  LOG_STARTED_AT="$(_log_clock)"
  LOG_LAST_HUMAN_LINE=''
  log_event start "$LOG_ACTION" running 'Command started' "{\"issue\":\"$LOG_ISSUE_ID\"}"
  printf 'Detailed log: %s\n' "$LOG_FILE"
  trap '_log_exit_trap "$?"' EXIT
}

phase() {
  local message="$*"
  log_event progress "${LOG_ACTION}.legacy_progress" running "$message"
}

_run_logged() {
  local visibility="$1" description="$2" status capture arg previous='' redacted action_slug line started_at finished_at duration details
  shift 2
  [ "$#" -gt 0 ] || { fail_with_log "$description (missing command)" 2; return 2; }
  action_slug="$(_log_action_slug "$description")"
  details="$(_run_logged_details "$visibility")"
  log_event progress "${LOG_ACTION}.${action_slug}" running "$description" "$details"
  {
    printf '[%s] command' "$(_log_timestamp)"
    for arg in "$@"; do
      redacted="$(_log_safe_arg "$arg" "$previous")"
      printf ' %q' "$redacted"
      previous="$arg"
    done
    printf '\n'
  } >> "$LOG_FILE"
  capture="$(mktemp "${TMPDIR:-/tmp}/c2s-log-output.XXXXXX")" || return 1
  started_at="$(_log_clock)"
  if "$@" >"$capture" 2>&1; then
    status=0
  else
    status=$?
  fi
  finished_at="$(_log_clock)"
  duration="$(_log_duration "$started_at" "$finished_at")"
  LOG_LAST_OUTPUT=''
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${WORKSPACE_EVENT_STREAM:-false}" = true ] && [[ "$line" == VDD_EVENT\ * ]]; then
      printf '%s\n' "$line" >&2
      continue
    fi
    redacted="$(_redact_text "$line")"
    LOG_LAST_OUTPUT+="$redacted"$'\n'
    printf '%s\n' "$redacted" >> "$LOG_FILE"
  done < "$capture"
  rm -f "$capture"
  printf '[%s] command_status=%s\n' "$(_log_timestamp)" "$status" >> "$LOG_FILE"
  if [ "$status" -eq 0 ]; then
    log_event success "${LOG_ACTION}.${action_slug}" success "$description completed" "$details" "$duration"
  else
    log_event error "${LOG_ACTION}.${action_slug}" error "$description failed" "{\"exit\":$status,\"display\":\"$visibility\"}" "$duration"
  fi
  return "$status"
}

run_logged() {
  _run_logged audit "$@"
}

run_logged_visible() {
  _run_logged terminal "$@"
}

run_logged_capture() {
  local description="$1"
  shift
  run_logged "$description" "$@"
}

run_logged_capture_visible() {
  local description="$1"
  shift
  run_logged_visible "$description" "$@"
}

finish_log() {
  local status="${1:-success}"
  [ -n "${LOG_FILE:-}" ] || { printf 'ERROR: Logging has not started\n' >&2; return 1; }
  _log_finish_file "$status"
}

fail_with_log() {
  local description="$1" status="${2:-1}"
  log_event error "${LOG_ACTION}.failure" error "$description" "{\"exit\":$status}"
  _log_finish_file "failed:$status"
  return "$status"
}
