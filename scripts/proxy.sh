#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

action="${1:-}"
[ "$#" -eq 1 ] || die "Usage: proxy.sh {register|unregister|status}"
case "$action" in
  register|unregister|status) ;;
  *) die "Usage: proxy.sh {register|unregister|status}" ;;
esac

load_config

default_shared_proxy_root="/home/marcodotcastro/.config/c2s-crm-worktree-proxy"
proxy_layout_exists() {
  local root="$1"
  [ -f "$root/docker-compose.yml" ] &&
    [ -f "$root/Caddyfile" ] &&
    [ -d "$root/routes" ]
}

configured_proxy_root="${WORKSPACE_PROXY_ROOT:-}"
if [ -n "$configured_proxy_root" ]; then
  proxy_dir="$configured_proxy_root"
else
  if proxy_layout_exists "$default_shared_proxy_root"; then
    proxy_dir="$default_shared_proxy_root"
  else
    proxy_dir="$STATE_DIR/proxy"
  fi
fi

shared_proxy=false
fallback_marker="$proxy_dir/.workspace-fallback"
if [ ! -f "$fallback_marker" ] &&
    ! compgen -G "$proxy_dir/routes/*.env" > /dev/null &&
    proxy_layout_exists "$proxy_dir"; then
  shared_proxy=true
  proxy_project="c2s_crm_worktree_proxy"
  route_extension="caddy"
else
  proxy_project="${WORKSPACE_PROXY_PROJECT:-c2s-workspace-proxy}"
  route_extension="env"
fi

routes_dir="$proxy_dir/routes"
pages_dir="$proxy_dir/pages"
caddy_file="$proxy_dir/Caddyfile"
proxy_compose_file="$proxy_dir/docker-compose.yml"
public_listener_ports=(80 3000 3001 3002 3003)

proxy_edge_network_name() {
  local network="${WORKSPACE_EDGE_NETWORK:-c2s_workspace_edge}"
  [[ "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    die "WORKSPACE_EDGE_NETWORK is invalid: $network"
    return 1
  }
  printf '%s\n' "$network"
}

normalize_caddy_service() {
  local temporary_compose
  grep -Eq '^  caddy:[[:space:]]*(#.*)?$' "$proxy_compose_file" || \
    die "Proxy Compose is missing the caddy service: $proxy_compose_file"

  temporary_compose="$(mktemp "$proxy_dir/.docker-compose.XXXXXX")"
  if ! awk '
    function is_caddy_header(line) {
      return line ~ /^  caddy:[[:space:]]*(#.*)?$/
    }
    function is_caddy_field(line) {
      return line ~ /^    [^[:space:]#][^:]*:[[:space:]]*/
    }
    function field_name(line, value, colon) {
      value = substr(line, 5)
      colon = index(value, ":")
      value = substr(value, 1, colon - 1)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function normalize_network_name(value, first, last) {
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") || \
          (first == sprintf("%c", 39) && last == sprintf("%c", 39))) {
        value = substr(value, 2, length(value) - 2)
      }
      return value
    }
    function add_network(value, normalized, i) {
      normalized = normalize_network_name(value)
      if (normalized == "" || normalized == "null") return
      for (i = 1; i <= network_count; i++) {
        if (network_name[i] == normalized) return
      }
      network_name[++network_count] = normalized
    }
    function parse_inline_networks(line, value, item, count, i) {
      value = line
      sub(/^    networks:[^[]*\[/, "", value)
      sub(/\][^]]*$/, "", value)
      count = split(value, item, ",")
      for (i = 1; i <= count; i++) add_network(item[i])
    }
    function parse_network_line(line, value) {
      if (line ~ /^    networks:[^[]*\[/) parse_inline_networks(line)
      if (line ~ /^      -[[:space:]]+/) {
        value = line
        sub(/^      -[[:space:]]+/, "", value)
        add_network(value)
      }
      if (line ~ /^      [^[:space:]#-][^:]*:/) {
        value = substr(line, 7)
        sub(/:.*/, "", value)
        add_network(value)
      }
    }
    function append_ports() {
      print "    ports:"
      print "      - \"80:80\""
      print "      - \"3000:3000\""
      print "      - \"3001:3001\""
      print "      - \"3002:3002\""
      print "      - \"3003:3003\""
    }
    function append_networks(i) {
      print "    networks:"
      for (i = 1; i <= network_count; i++) print "      - " network_name[i]
    }
    function clear_caddy_lines(i) {
      for (i in caddy_line) delete caddy_line[i]
      caddy_count = 0
    }
    function render_caddy( i, j, k, line, name, ports_printed, networks_printed) {
      network_count = 0
      for (i = 2; i <= caddy_count; i++) {
        line = caddy_line[i]
        if (!is_caddy_field(line)) continue
        name = field_name(line)
        j = i + 1
        while (j <= caddy_count && !is_caddy_field(caddy_line[j])) j++
        if (name == "networks") {
          parse_network_line(line)
          for (k = i + 1; k < j; k++) parse_network_line(caddy_line[k])
        }
        i = j - 1
      }
      add_network("edge")

      print caddy_line[1]
      for (i = 2; i <= caddy_count;) {
        line = caddy_line[i]
        if (!is_caddy_field(line)) {
          print line
          i++
          continue
        }
        name = field_name(line)
        j = i + 1
        while (j <= caddy_count && !is_caddy_field(caddy_line[j])) j++
        if (name == "ports") {
          if (!ports_printed) {
            append_ports()
            ports_printed = 1
          }
        } else if (name == "networks") {
          if (!networks_printed) {
            append_networks()
            networks_printed = 1
          }
        } else {
          for (k = i; k < j; k++) print caddy_line[k]
        }
        i = j
      }
      if (!ports_printed) append_ports()
      if (!networks_printed) append_networks()
      clear_caddy_lines()
    }
    {
      if (is_caddy_header($0)) {
        if (in_caddy) render_caddy()
        clear_caddy_lines()
        in_caddy = 1
        caddy_seen = 1
        caddy_line[++caddy_count] = $0
        next
      }
      if (in_caddy && ($0 ~ /^  [^[:space:]#][^:]*:/ || \
                       $0 ~ /^[^[:space:]#][^:]*:/)) {
        render_caddy()
        in_caddy = 0
        print
        next
      }
      if (in_caddy) {
        caddy_line[++caddy_count] = $0
        next
      }
      print
    }
    END {
      if (in_caddy) render_caddy()
      if (!caddy_seen) exit 1
    }
  ' "$proxy_compose_file" > "$temporary_compose"; then
    rm -f -- "$temporary_compose"
    die "Could not normalize Caddy service in Compose: $proxy_compose_file"
  fi
  if ! chmod 600 "$temporary_compose" || ! mv -f -- "$temporary_compose" "$proxy_compose_file"; then
    rm -f -- "$temporary_compose"
    die "Could not replace normalized Compose: $proxy_compose_file"
  fi
}

normalize_edge_network_declaration() {
  local network_name="$1" temporary_compose
  temporary_compose="$(mktemp "$proxy_dir/.docker-compose.XXXXXX")"
  if ! awk -v network_name="$network_name" '
    function append_edge_declaration() {
      print "  edge:"
      print "    name: " network_name
      print "    external: true"
      edge_seen = 1
    }
    function append_edge_fields() {
      if (!edge_name_seen) print "    name: " network_name
      if (!edge_external_seen) print "    external: true"
    }
    function close_edge() {
      if (in_edge) {
        append_edge_fields()
        in_edge = 0
      }
    }
    function close_networks() {
      close_edge()
      if (in_networks && !edge_seen) append_edge_declaration()
      in_networks = 0
    }
    /^networks:[[:space:]]*(#.*)?$/ {
      if (in_networks) close_networks()
      in_networks = 1
      networks_seen = 1
      print
      next
    }
    in_networks && /^  edge:[[:space:]]*/ {
      close_edge()
      edge_seen = 1
      in_edge = 1
      edge_name_seen = 0
      edge_external_seen = 0
      print "  edge:"
      if ($0 !~ /^  edge:[[:space:]]*(#.*)?$/) {
        print "    name: " network_name
        print "    external: true"
        in_edge = 0
      }
      next
    }
    in_networks && /^  [^[:space:]#][^:]*:/ {
      close_edge()
      if (!edge_seen) append_edge_declaration()
      print
      next
    }
    in_networks && /^[^[:space:]#][^:]*:/ {
      close_networks()
      print
      next
    }
    in_edge && /^    name:[[:space:]]*/ {
      print "    name: " network_name
      edge_name_seen = 1
      next
    }
    in_edge && /^    external:[[:space:]]*/ {
      print "    external: true"
      edge_external_seen = 1
      next
    }
    { print }
    END {
      if (in_networks) close_networks()
      if (!networks_seen) {
        print ""
        print "networks:"
        append_edge_declaration()
      }
    }
  ' "$proxy_compose_file" > "$temporary_compose"; then
    rm -f -- "$temporary_compose"
    die "Could not normalize the Compose edge network: $proxy_compose_file"
  fi
  if ! chmod 600 "$temporary_compose" || ! mv -f -- "$temporary_compose" "$proxy_compose_file"; then
    rm -f -- "$temporary_compose"
    die "Could not replace normalized Compose: $proxy_compose_file"
  fi
}

normalize_proxy_compose() {
  local network_name
  network_name="$(proxy_edge_network_name)"
  normalize_caddy_service
  normalize_edge_network_declaration "$network_name"
}

ensure_dashboard_mount() {
  local temporary_compose

  if awk '
    /^  caddy:[[:space:]]*(#.*)?$/ { in_caddy = 1; next }
    in_caddy && /^  [^[:space:]].*:/ { in_caddy = 0; in_volumes = 0 }
    in_caddy && /^    volumes:[[:space:]]*$/ { in_volumes = 1; next }
    in_caddy && in_volumes && /^    [^[:space:]].*:/ { in_volumes = 0 }
    in_caddy && in_volumes && /^[[:space:]]*-[[:space:]]+[^#]*:[[:space:]]*\/srv\/pages(:|[[:space:]]|$)/ {
      found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$proxy_compose_file"; then
    return 0
  fi

  temporary_compose="$(mktemp "$proxy_dir/.docker-compose.XXXXXX")"
  if ! awk '
    /^  caddy:[[:space:]]*(#.*)?$/ { in_caddy = 1; print; next }
    in_caddy && /^  [^[:space:]].*:/ { in_caddy = 0; in_volumes = 0 }
    in_caddy && !inserted && in_volumes &&
      $0 ~ /^[[:space:]]*-[[:space:]]+[^#]*:\/etc\/caddy\/Caddyfile(:|[[:space:]]|$)/ {
      print
      print "      - ./pages:/srv/pages:ro"
      inserted = 1
      next
    }
    in_caddy && !inserted && /^    volumes:[[:space:]]*$/ {
      print
      print "      - ./pages:/srv/pages:ro"
      inserted = 1
      in_volumes = 1
      next
    }
    in_caddy && in_volumes && /^    [^[:space:]].*:/ { in_volumes = 0 }
    in_caddy && /^    volumes:[[:space:]]*$/ { in_volumes = 1 }
    { print }
    END { if (!inserted) exit 1 }
  ' "$proxy_compose_file" > "$temporary_compose"; then
    rm -f -- "$temporary_compose"
    die "Could not add the dashboard mount to Caddy Compose: $proxy_compose_file"
  fi
  if ! chmod 600 "$temporary_compose" || ! mv -f -- "$temporary_compose" "$proxy_compose_file"; then
    rm -f -- "$temporary_compose"
    die "Could not replace Compose with the dashboard mount: $proxy_compose_file"
  fi
}

ensure_proxy_files() {
  mkdir -p "$routes_dir"
  if [ -e "$pages_dir" ] && { [ ! -d "$pages_dir" ] || [ -L "$pages_dir" ]; }; then
    die "Proxy pages path must be a real directory: $pages_dir"
  fi
  mkdir -p "$pages_dir"
  chmod 700 "$pages_dir"
  if [ "$shared_proxy" = false ] && [ ! -f "$fallback_marker" ]; then
    umask 077
    : > "$fallback_marker"
  fi
  if [ ! -f "$proxy_compose_file" ]; then
    umask 077
    edge_network_name="$(proxy_edge_network_name)"
    cat > "$proxy_compose_file" <<COMPOSE
services:
  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
      - "3000:3000"
      - "3001:3001"
      - "3002:3002"
      - "3003:3003"
    networks:
      - edge
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./pages:/srv/pages:ro
      - caddy-data:/data
      - caddy-config:/config

volumes:
  caddy-data:
  caddy-config:

networks:
  edge:
    name: $edge_network_name
    external: true
COMPOSE
    chmod 600 "$proxy_compose_file"
  fi
  ensure_dashboard_mount
  normalize_proxy_compose
  if [ ! -f "$caddy_file" ]; then
    umask 077
    printf '{\n  auto_https off\n}\n\n' > "$caddy_file"
    chmod 600 "$caddy_file"
  fi
}

route_start_line() {
  sed -n '1p' "$1"
}

render_managed_route_unit() {
  local issue_id="$1" primary_host="$2" secondary_host="$3"
  local aio_alias="$4" backend_alias="$5" host_prefix="${6-http://}"
  printf '%s%s, %s%s {\n' "$host_prefix" "$primary_host" "$host_prefix" "$secondary_host"
  printf '  root * /srv/pages/%s\n' "$issue_id"
  printf '  file_server\n'
  printf '}\n\n'
  printf '%s%s:3000, %s%s:3000 {\n' "$host_prefix" "$primary_host" "$host_prefix" "$secondary_host"
  printf '  reverse_proxy %s:3000\n' "$aio_alias"
  printf '}\n\n'
  printf '%s%s:3001, %s%s:3001 {\n' "$host_prefix" "$primary_host" "$host_prefix" "$secondary_host"
  printf '  reverse_proxy %s:3002\n' "$aio_alias"
  printf '}\n\n'
  printf '%s%s:3002, %s%s:3002 {\n' "$host_prefix" "$primary_host" "$host_prefix" "$secondary_host"
  printf '  reverse_proxy %s:3000\n' "$backend_alias"
  printf '}\n\n'
  printf '%s%s:3003, %s%s:3003 {\n' "$host_prefix" "$primary_host" "$host_prefix" "$secondary_host"
  printf '  reverse_proxy %s:6006\n' "$aio_alias"
  printf '}\n'
}

remove_caddy_route() {
  local route_file="$1" temporary_caddy start_line route_block_count
  [ -f "$caddy_file" ] || return 0
  start_line="$(route_start_line "$route_file")"
  [ -n "$start_line" ] || return 0
  route_block_count="$(awk '/^http:\/\/.*\{[[:space:]]*$/ { count++ } END { print count + 0 }' "$route_file")"
  [ "$route_block_count" -gt 0 ] || return 0
  temporary_caddy="$(mktemp "$proxy_dir/.Caddyfile.XXXXXX")"
  awk -v start_line="$start_line" -v expected_blocks="$route_block_count" '
    function brace_delta(line, opens, closes) {
      opens = gsub(/\{/, "", line)
      closes = gsub(/\}/, "", line)
      return opens - closes
    }
    !in_unit && $0 == start_line {
      in_unit = 1
      blocks = 1
      depth = brace_delta($0)
      in_block = (depth > 0)
      next
    }
    in_unit && in_block {
      depth += brace_delta($0)
      if (depth <= 0) {
        in_block = 0
        if (blocks >= expected_blocks) in_unit = 0
      }
      next
    }
    in_unit && blocks < expected_blocks && $0 == "" { next }
    in_unit && blocks < expected_blocks && $0 ~ /^http:\/\/.*\{[[:space:]]*$/ {
      blocks++
      depth = brace_delta($0)
      in_block = (depth > 0)
      next
    }
    in_unit {
      in_unit = 0
      print
      next
    }
    { print }
  ' "$caddy_file" > "$temporary_caddy"
  chmod 600 "$temporary_caddy"
  mv -f "$temporary_caddy" "$caddy_file"
}

append_caddy_route() {
  local route_file="$1" temporary_caddy
  temporary_caddy="$(mktemp "$proxy_dir/.Caddyfile.XXXXXX")"
  umask 077
  if [ -f "$caddy_file" ]; then
    cat "$caddy_file" > "$temporary_caddy"
  fi
  if [ -s "$temporary_caddy" ] &&
      [ "$(tail -c 1 "$temporary_caddy" | od -An -t x1 | tr -d '[:space:]')" != '0a' ]; then
    printf '\n' >> "$temporary_caddy"
  fi
  cat "$route_file" >> "$temporary_caddy"
  printf '\n\n' >> "$temporary_caddy"
  chmod 600 "$temporary_caddy"
  mv -f "$temporary_caddy" "$caddy_file"
}

rebuild_fallback_caddyfile() {
  local route_file issue_id issue_number primary_host secondary_host crm_web_port route_mode
  local aio_alias backend_alias temporary_caddy
  temporary_caddy="$(mktemp "$proxy_dir/.Caddyfile.XXXXXX")"
  umask 077
  printf '{\n  auto_https off\n}\n\n' > "$temporary_caddy"
  for route_file in "$routes_dir"/*.env; do
    [ -f "$route_file" ] || continue
    issue_id="$(sed -n 's/^ISSUE_ID=//p' "$route_file" | head -n 1)"
    issue_number="$(sed -n 's/^ISSUE_NUMBER=//p' "$route_file" | head -n 1)"
    primary_host="$(sed -n 's/^WORKTREE_PRIMARY_HOST=//p' "$route_file" | head -n 1)"
    secondary_host="$(sed -n 's/^WORKTREE_SECONDARY_HOST=//p' "$route_file" | head -n 1)"
    crm_web_port="$(sed -n 's/^CRM_WEB_PORT=//p' "$route_file" | head -n 1)"
    route_mode="$(sed -n 's/^ROUTE_MODE=//p' "$route_file" | head -n 1)"
    [[ "$issue_id" =~ ^CC-[1-9][0-9]*$ ]] || die "Invalid proxy route issue: $route_file"
    [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || die "Invalid proxy route issue number: $route_file"
    [[ "$primary_host" =~ ^[a-z0-9.-]+$ ]] || die "Invalid proxy route host: $route_file"
    [[ "$secondary_host" =~ ^[a-z0-9.-]+$ ]] || die "Invalid proxy route host: $route_file"
    [[ "$crm_web_port" =~ ^[0-9]+$ ]] || die "Invalid proxy route port: $route_file"
    if [ "$route_mode" = file_server ]; then
      aio_alias="cc${issue_number}-aio"
      backend_alias="cc${issue_number}-backend"
      render_managed_route_unit \
        "$issue_id" "$primary_host" "$secondary_host" \
        "$aio_alias" "$backend_alias" "" >> "$temporary_caddy"
    else
      printf '%s, %s {\n' "$primary_host" "$secondary_host" >> "$temporary_caddy"
      printf '  reverse_proxy host.docker.internal:%s\n' "$crm_web_port" >> "$temporary_caddy"
      printf '}\n\n' >> "$temporary_caddy"
    fi
  done
  chmod 600 "$temporary_caddy"
  mv -f "$temporary_caddy" "$caddy_file"
}

html_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

write_dashboard_page() {
  local dashboard_dir="$pages_dir/$ISSUE_ID" temporary_page
  local issue_id_html shell_url_html backend_url_html
  local imob_url_html styleguide_url_html
  mkdir -p "$dashboard_dir"
  chmod 700 "$dashboard_dir"

  issue_id_html="$(html_escape "$ISSUE_ID")"
  shell_url_html="$(html_escape "$SHELL_URL")"
  backend_url_html="$(html_escape "$BACKEND_URL")"
  imob_url_html="$(html_escape "$IMOB_URL")"
  styleguide_url_html="$(html_escape "$STYLEGUIDE_URL")"

  temporary_page="$(mktemp "$dashboard_dir/.index.html.XXXXXX")"
  umask 077
  cat > "$temporary_page" <<HTML
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$issue_id_html Workspace</title>
    <style>
      :root { color-scheme: light; font-family: system-ui, sans-serif; }
      body { margin: 0; background: #f5f8fc; color: #13243a; }
      main { box-sizing: border-box; max-width: 44rem; margin: 0 auto; padding: 3rem 1.5rem; }
      header { display: flex; align-items: center; gap: 1rem; margin-bottom: 2rem; }
      .brand-lockup { flex: 0 0 auto; text-align: center; }
      .brand-pill { display: inline-flex; align-items: center; gap: .375rem; padding: .5rem .75rem; border-radius: .375rem; background: #155da8; box-shadow: 0 1px 4px #13243a1f; }
      .brand-c2s, .brand-imob { font-size: 1.875rem; letter-spacing: -.025em; line-height: 1; user-select: none; }
      .brand-c2s { color: #fff; font-weight: 700; }
      .brand-imob { color: #73d2b0; font-weight: 300; }
      .brand-tagline { margin: .5rem 0 0; color: #52657b; font-size: .75rem; }
      h1 { margin: 0; font-size: 1.75rem; }
      p { color: #52657b; }
      ul { display: grid; gap: .75rem; list-style: none; margin: 0; padding: 0; }
      a { display: block; padding: 1rem; border-radius: .75rem; background: #fff; color: #155da8; font-weight: 650; text-decoration: none; box-shadow: 0 1px 4px #13243a1f; }
      a:hover { background: #eaf3ff; }
    </style>
  </head>
  <body>
    <main>
      <header>
        <div class="brand-lockup" role="img" aria-label="C2S Imob">
          <div class="brand-pill">
            <span class="brand-c2s">C2S</span>
            <span class="brand-imob"> Imob</span>
          </div>
          <p class="brand-tagline">Gestão de Imóveis</p>
        </div>
        <div>
          <h1>$issue_id_html Workspace</h1>
          <p>Ambiente integrado de desenvolvimento</p>
        </div>
      </header>
      <nav aria-label="Workspace services">
        <ul>
          <li><a href="$shell_url_html">Shell</a></li>
          <li><a href="$imob_url_html">Imob</a></li>
          <li><a href="$backend_url_html">Backend</a></li>
          <li><a href="$styleguide_url_html">Styleguide</a></li>
        </ul>
      </nav>
    </main>
  </body>
</html>
HTML
  chmod 600 "$temporary_page"
  mv -f "$temporary_page" "$dashboard_dir/index.html"
}

remove_dashboard_page() {
  local dashboard_dir="$pages_dir/$ISSUE_ID"
  [ -e "$dashboard_dir" ] || return 0
  [ ! -L "$dashboard_dir" ] || die "Proxy dashboard path must not be a symlink: $dashboard_dir"
  rm -rf -- "$dashboard_dir"
}

reload_proxy() {
  require_command docker
  (cd "$proxy_dir" && docker compose --project-name "$proxy_project" -f "$proxy_compose_file" up -d --force-recreate caddy)
}

stop_proxy() {
  require_command docker
  (cd "$proxy_dir" && docker compose --project-name "$proxy_project" -f "$proxy_compose_file" down --remove-orphans)
}

assert_no_conflicting_public_ports() {
  local port running container project service occupied_ports=''
  require_command docker
  for port in "${public_listener_ports[@]}"; do
    if ! running="$(docker ps --filter "publish=$port" \
        --format '{{.ID}} {{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.service"}}' \
        2>/dev/null)"; then
      die "Could not inspect public port $port: docker ps query failed"
      return 1
    fi
    while IFS=' ' read -r container project service _; do
      [ -n "$container" ] || continue
      if [ "$project" = "$proxy_project" ]; then
        continue
      fi
      occupied_ports="${occupied_ports:+$occupied_ports, }$port"
      break
    done <<< "$running"
  done
  [ -z "$occupied_ports" ] || \
    die "Public port(s) occupied: $occupied_ports"
}

case "$action" in
  status)
    if [ -f "$caddy_file" ]; then
      cat "$caddy_file"
    else
      printf 'No proxy routes registered.\n'
    fi
    exit 0
    ;;
esac

selected_issue_state
if [ "$action" != unregister ] || [ "${WORKSPACE_ALLOW_MISSING_WORKTREES:-false}" != true ]; then
  derive_runtime_routes
fi

runtime_env_file="$STATE_DIR/runtime/$ISSUE_ID/compose.env"
runtime_env_value() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" "$runtime_env_file" | head -n 1)"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

if [ "$action" != unregister ] && [ -f "$runtime_env_file" ]; then
  WORKSPACE_URL="$(runtime_env_value WORKSPACE_URL)"
  if ! SHELL_URL="$(runtime_env_value SHELL_URL)"; then
    SHELL_URL="$(runtime_env_value ALL_IN_ONE_URL)"
  fi
  BACKEND_URL="$(runtime_env_value BACKEND_URL)"
  IMOB_URL="$(runtime_env_value IMOB_URL)"
  STYLEGUIDE_URL="$(runtime_env_value STYLEGUIDE_URL)"
elif [ "$action" != unregister ]; then
  WORKSPACE_URL="http://$WORKTREE_PRIMARY_HOST"
  SHELL_URL="$WORKSPACE_URL:$AIO_ALL_IN_ONE_PORT"
  BACKEND_URL="$WORKSPACE_URL:$CRM_WEB_PORT"
  IMOB_URL="$WORKSPACE_URL:$AIO_IMOB_PORT"
  STYLEGUIDE_URL="$WORKSPACE_URL:$AIO_STYLEGUIDE_PORT"
fi
if [ "$action" = register ]; then
  assert_no_conflicting_public_ports
fi
ensure_proxy_files
route_file="$routes_dir/cc-$ISSUE_NUMBER.$route_extension"

case "$action" in
  register)
    if [ "$shared_proxy" = true ]; then
      temporary_route="$(mktemp "$routes_dir/.route.XXXXXX")"
      trap 'rm -f "$temporary_route"' EXIT
      umask 077
      render_managed_route_unit \
        "$ISSUE_ID" "$WORKTREE_PRIMARY_HOST" "$WORKTREE_SECONDARY_HOST" \
        "$WORKSPACE_AIO_ALIAS" "$WORKSPACE_BACKEND_ALIAS" > "$temporary_route"
      chmod 600 "$temporary_route"
      if [ -f "$route_file" ]; then
        remove_caddy_route "$route_file"
      fi
      mv -f "$temporary_route" "$route_file"
      trap - EXIT
      append_caddy_route "$route_file"
    else
      temporary_route="$(mktemp "$routes_dir/.route.XXXXXX")"
      trap 'rm -f "$temporary_route"' EXIT
      umask 077
      {
        printf 'ISSUE_ID=%s\n' "$ISSUE_ID"
        printf 'ISSUE_NUMBER=%s\n' "$ISSUE_NUMBER"
        printf 'WORKTREE_PRIMARY_HOST=%s\n' "$WORKTREE_PRIMARY_HOST"
        printf 'WORKTREE_SECONDARY_HOST=%s\n' "$WORKTREE_SECONDARY_HOST"
        printf 'CRM_WEB_PORT=%s\n' "$CRM_WEB_PORT"
        printf 'ROUTE_MODE=file_server\n'
      } > "$temporary_route"
      chmod 600 "$temporary_route"
      mv -f "$temporary_route" "$route_file"
      trap - EXIT
      rebuild_fallback_caddyfile
    fi
    write_dashboard_page
    reload_proxy
    printf 'Registered proxy route for %s.\n' "$ISSUE_ID"
    ;;
  unregister)
    remove_dashboard_page
    if [ -f "$route_file" ]; then
      if [ "$shared_proxy" = true ]; then
        remove_caddy_route "$route_file"
      fi
      rm -f "$route_file"
    fi
    if [ "$shared_proxy" = true ]; then
      reload_proxy
    elif compgen -G "$routes_dir/*.env" > /dev/null; then
      rebuild_fallback_caddyfile
      reload_proxy
    else
      rebuild_fallback_caddyfile
      stop_proxy
    fi
    printf 'Unregistered proxy route for %s.\n' "$ISSUE_ID"
    ;;
esac
