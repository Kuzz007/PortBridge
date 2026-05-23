#!/usr/bin/env bash
# portbridge.sh
# TCP/UDP port forwarding manager for frontend VPS -> backend IP:port.

set -Eeuo pipefail

VERSION="0.1.0"
APP_NAME="PortBridge"
BIN_PATH="/usr/local/bin/portbridge"
COMMENT_PREFIX="portbridge"
SYSCTL_FILE="/etc/sysctl.d/99-portbridge.conf"

ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запусти от root."
    exit 1
  fi
}

valid_proto() {
  [[ "${1:-}" == "tcp" || "${1:-}" == "udp" ]]
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_deps() {
  info "Проверяю зависимости..."
  if need_cmd apt-get; then
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent netfilter-persistent iproute2 grep sed awk coreutils
  elif need_cmd dnf; then
    dnf install -y iptables iptables-services iproute grep sed awk coreutils || true
  elif need_cmd yum; then
    yum install -y iptables iptables-services iproute grep sed awk coreutils || true
  elif need_cmd apk; then
    apk add --no-cache iptables iproute2 grep sed awk coreutils || true
  else
    warn "Неизвестный пакетный менеджер. Убедись, что iptables/ip/sysctl установлены."
  fi

  local missing=()
  for cmd in iptables iptables-save ip ip_forward_dummy grep sed awk sysctl; do
    [[ "$cmd" == "ip_forward_dummy" ]] && continue
    need_cmd "$cmd" || missing+=("$cmd")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    err "Не найдены команды: ${missing[*]}"
    exit 1
  fi
  ok "Зависимости готовы."
}

enable_forwarding() {
  need_root
  info "Включаю IPv4 forwarding..."
  cat > "$SYSCTL_FILE" <<EOF_SYSCTL
# Managed by PortBridge
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF_SYSCTL
  sysctl --system >/dev/null || sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ok "IPv4 forwarding включён."
}

install_self() {
  need_root
  install_deps
  enable_forwarding
  if [[ "$(readlink -f "$0")" != "$BIN_PATH" ]]; then
    install -m 0755 "$0" "$BIN_PATH"
    ok "Установлена команда: portbridge"
  else
    ok "Команда portbridge уже установлена."
  fi
  save_rules
}

get_iface() {
  local target="${1:-8.8.8.8}" iface
  iface="$(ip route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  [[ -n "$iface" ]] || iface="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  printf '%s' "$iface"
}

save_rules() {
  if need_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif need_cmd service; then
    service iptables save >/dev/null 2>&1 || true
  fi
}

ufw_allow_if_active() {
  local proto="$1" port="$2"
  if need_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/${proto}" >/dev/null || true
    if [[ -f /etc/default/ufw ]]; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    fi
    ufw reload >/dev/null || true
  fi
}

rule_comment() {
  local proto="$1" in_port="$2" target_ip="$3" out_port="$4"
  printf '%s:%s:%s:%s:%s' "$COMMENT_PREFIX" "$proto" "$in_port" "$target_ip" "$out_port"
}

iptables_add_once() {
  local table="$1"; shift
  if [[ "$table" == "filter" ]]; then
    iptables -C "$@" 2>/dev/null || iptables -A "$@"
  else
    iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
  fi
}

add_rule() {
  need_root
  local proto="${1:-}" in_port="${2:-}" target_ip="${3:-}" out_port="${4:-}"
  valid_proto "$proto" || { err "Протокол должен быть tcp или udp."; exit 1; }
  valid_port "$in_port" || { err "Некорректный входящий порт: $in_port"; exit 1; }
  valid_port "$out_port" || { err "Некорректный исходящий порт: $out_port"; exit 1; }
  [[ -n "$target_ip" ]] || { err "TARGET_IP пустой."; exit 1; }

  enable_forwarding

  local iface comment
  iface="$(get_iface "$target_ip")"
  [[ -n "$iface" ]] || { err "Не удалось определить внешний интерфейс."; exit 1; }
  comment="$(rule_comment "$proto" "$in_port" "$target_ip" "$out_port")"

  info "Добавляю bridge: ${proto} ${in_port} -> ${target_ip}:${out_port}, iface=${iface}"

  iptables_add_once filter INPUT -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j ACCEPT
  iptables_add_once nat PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${out_port}"
  iptables_add_once nat POSTROUTING -o "$iface" -m comment --comment "$comment" -j MASQUERADE
  iptables_add_once filter FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT
  iptables_add_once filter FORWARD -p "$proto" -s "$target_ip" --sport "$out_port" -m state --state ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT

  ufw_allow_if_active "$proto" "$in_port"
  save_rules
  ok "Готово: ${proto} ${in_port} -> ${target_ip}:${out_port}"
}

add_both() {
  local in_port="${1:-}" target_ip="${2:-}" out_port="${3:-}"
  add_rule tcp "$in_port" "$target_ip" "$out_port"
  add_rule udp "$in_port" "$target_ip" "$out_port"
}

matching_comment_line() {
  local comment="$1" proto_filter="${2:-}" port_filter="${3:-}"
  [[ "$comment" == ${COMMENT_PREFIX}:* ]] || return 1
  [[ -z "$proto_filter" || "$comment" == ${COMMENT_PREFIX}:${proto_filter}:* ]] || return 1
  [[ -z "$port_filter" || "$comment" == ${COMMENT_PREFIX}:*:${port_filter}:* ]] || return 1
}

delete_rules_by_filter() {
  need_root
  local proto_filter="${1:-}" port_filter="${2:-}" tmp table line comment cmd changed=0
  tmp="$(mktemp)"
  iptables-save > "$tmp"

  table=""
  while IFS= read -r line; do
    case "$line" in
      \**)
        table="${line#\*}"
        ;;
      -A*)
        comment="$(printf '%s\n' "$line" | sed -n 's/.*--comment "\([^"]*\)".*/\1/p')"
        [[ -n "$comment" ]] || continue
        matching_comment_line "$comment" "$proto_filter" "$port_filter" || continue
        cmd="${line/-A /-D }"
        if [[ "$table" == "filter" ]]; then
          # shellcheck disable=SC2086
          iptables $cmd 2>/dev/null || true
        else
          # shellcheck disable=SC2086
          iptables -t "$table" $cmd 2>/dev/null || true
        fi
        changed=1
        ;;
    esac
  done < "$tmp"

  rm -f "$tmp"
  save_rules
  [[ "$changed" == "1" ]] && ok "Правила удалены." || warn "Подходящие правила не найдены."
}

remove_rule() {
  local proto="${1:-}" in_port="${2:-}"
  valid_proto "$proto" || { err "Протокол должен быть tcp или udp."; exit 1; }
  valid_port "$in_port" || { err "Некорректный порт: $in_port"; exit 1; }
  delete_rules_by_filter "$proto" "$in_port"
}

purge_rules() {
  need_root
  echo "Это удалит только iptables-правила с comment '${COMMENT_PREFIX}:*'."
  read -rp "Продолжить? [y/N]: " ans
  case "$ans" in y|Y|yes|YES|да|Да) ;; *) echo "Отменено."; return 0 ;; esac
  delete_rules_by_filter "" ""
}

list_rules() {
  echo "============================================================"
  echo "PORTBRIDGE RULES"
  echo "============================================================"
  local found=0 line comment proto in_port target out_port
  while IFS= read -r line; do
    comment="$(printf '%s\n' "$line" | sed -n 's/.*--comment "\([^"]*\)".*/\1/p')"
    [[ "$comment" == ${COMMENT_PREFIX}:* ]] || continue
    IFS=':' read -r _ proto in_port target out_port <<< "$comment"
    [[ "$line" == *"-A PREROUTING"* ]] || continue
    printf '%-5s %-8s -> %-21s  comment=%s\n' "$proto" "$in_port" "${target}:${out_port}" "$comment"
    found=1
  done < <(iptables-save 2>/dev/null || true)
  [[ "$found" == "1" ]] || echo "Правил PortBridge нет."
}

doctor() {
  echo "============================================================"
  echo "PORTBRIDGE DOCTOR"
  echo "============================================================"
  local ok_count=0 warn_count=0 fail_count=0
  check_ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$1"; ok_count=$((ok_count+1)); }
  check_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; warn_count=$((warn_count+1)); }
  check_fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; fail_count=$((fail_count+1)); }

  [[ "${EUID}" -eq 0 ]] && check_ok "root" || check_fail "нужно root"
  for cmd in iptables iptables-save ip sysctl grep sed awk; do
    need_cmd "$cmd" && check_ok "$cmd найден" || check_fail "$cmd не найден"
  done
  [[ -x "$BIN_PATH" ]] && check_ok "$BIN_PATH установлен" || check_warn "$BIN_PATH не установлен"
  [[ -r /proc/sys/net/ipv4/ip_forward && "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] && check_ok "ip_forward=1" || check_warn "ip_forward не включён"
  local iface
  iface="$(get_iface 8.8.8.8)"
  [[ -n "$iface" ]] && check_ok "default iface: $iface" || check_warn "default iface не найден"
  local count
  count="$(iptables-save 2>/dev/null | grep -c -- "--comment \"${COMMENT_PREFIX}:")" || count="0"
  check_ok "PortBridge iptables rules: $count"
  if need_cmd ufw; then
    ufw status 2>/dev/null | head -n1 || true
  fi
  echo
  echo "Итог: OK=$ok_count WARN=$warn_count FAIL=$fail_count"
}

show_help() {
  cat <<EOF_HELP
${APP_NAME} v${VERSION}

Usage:
  portbridge --install
  portbridge --add tcp IN_PORT TARGET_IP OUT_PORT
  portbridge --add udp IN_PORT TARGET_IP OUT_PORT
  portbridge --add-both IN_PORT TARGET_IP OUT_PORT
  portbridge --list
  portbridge --remove tcp IN_PORT
  portbridge --remove udp IN_PORT
  portbridge --purge
  portbridge --doctor
  portbridge --version

Examples:
  portbridge --add tcp 443 1.2.3.4 443
  portbridge --add udp 51820 1.2.3.4 51820
  portbridge --add-both 443 1.2.3.4 443
EOF_HELP
}

menu() {
  while true; do
    clear || true
    cat <<EOF_MENU
============================================================
 PortBridge v${VERSION}
============================================================
 1) Install / update
 2) Add TCP bridge
 3) Add UDP bridge
 4) Add TCP+UDP bridge
 5) List rules
 6) Remove rule
 7) Doctor
 8) Purge PortBridge rules
 0) Exit
============================================================
EOF_MENU
    read -rp "Select: " choice
    case "$choice" in
      1) install_self; read -rp "Enter..." _ || true ;;
      2) read -rp "IN_PORT: " a; read -rp "TARGET_IP: " b; read -rp "OUT_PORT: " c; add_rule tcp "$a" "$b" "$c"; read -rp "Enter..." _ || true ;;
      3) read -rp "IN_PORT: " a; read -rp "TARGET_IP: " b; read -rp "OUT_PORT: " c; add_rule udp "$a" "$b" "$c"; read -rp "Enter..." _ || true ;;
      4) read -rp "IN_PORT: " a; read -rp "TARGET_IP: " b; read -rp "OUT_PORT: " c; add_both "$a" "$b" "$c"; read -rp "Enter..." _ || true ;;
      5) list_rules; read -rp "Enter..." _ || true ;;
      6) read -rp "PROTO tcp/udp: " a; read -rp "IN_PORT: " b; remove_rule "$a" "$b"; read -rp "Enter..." _ || true ;;
      7) doctor; read -rp "Enter..." _ || true ;;
      8) purge_rules; read -rp "Enter..." _ || true ;;
      0) exit 0 ;;
      *) echo "Unknown"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  --install) install_self ;;
  --add) add_rule "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  --add-both) add_both "${2:-}" "${3:-}" "${4:-}" ;;
  --list) list_rules ;;
  --remove) remove_rule "${2:-}" "${3:-}" ;;
  --purge) purge_rules ;;
  --doctor) doctor ;;
  --version|-v) echo "${APP_NAME} v${VERSION}" ;;
  --help|-h) show_help ;;
  "") menu ;;
  *) err "Unknown option: $1"; show_help; exit 1 ;;
esac
