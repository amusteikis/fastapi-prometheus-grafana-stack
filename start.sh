#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# start.sh — Levanta el stack y valida salud
# Proyecto: Prometheus + Grafana (+ Alertmanager)
# Reqs: Docker + Docker Compose v2 ("docker compose")
#############################################

# ---------- Config ----------
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROJECT_NAME="${PROJECT_NAME:-grafana-prometheus-stack}"
DOCKER_COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-docker compose}"

# Endpoints por defecto (podés override por env/.env)
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"

# Opcional: vars para validar Grafana (si las tenés provisionadas en .env)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

# Retries/tiempos
RETRIES="${RETRIES:-60}"
SLEEP_SECS="${SLEEP_SECS:-2}"

# ---------- Helpers ----------
log() { printf "\n\033[1;36m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
ok()  { printf "\033[1;32m✔\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m✖ %s\033[0m\n" "$*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { err "No se encontró '$1' en PATH"; exit 127; }
}

load_dotenv() {
  # Carga .env si existe (sin export masivo inseguro)
  if [[ -f .env ]]; then
    log "Cargando variables de .env"
    # shellcheck disable=SC2046
    export $(grep -Ev '^\s*#' .env | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | xargs -d '\n')
  fi
}

wait_http_ok() {
  local name="$1" url="$2" path="${3:-/}" expect="${4:-200}"
  local i=1
  while (( i <= RETRIES )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${url}${path}" || true)"
    if [[ "$code" == "$expect" ]]; then
      ok "$name responde $expect en ${path}"
      return 0
    fi
    printf "."
    sleep "$SLEEP_SECS"
    ((i++))
  done
  echo
  err "Timeout esperando $name (${url}${path}) -> $expect"
  return 1
}

wait_http_body_contains() {
  local name="$1" url="$2" path="$3" needle="$4"
  local i=1
  while (( i <= RETRIES )); do
    body="$(curl -fsS "${url}${path}" 2>/dev/null || true)"
    if [[ "$body" == *"$needle"* ]]; then
      ok "$name contiene '$needle' en ${path}"
      return 0
    fi
    printf "."
    sleep "$SLEEP_SECS"
    ((i++))
  done
  echo
  err "Timeout esperando contenido '$needle' en ${url}${path}"
  return 1
}

wait_tcp() {
  local name="$1" host="$2" port="$3"
  local i=1
  while (( i <= RETRIES )); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      ok "$name escucha en $host:$port"
      return 0
    fi
    printf "."
    sleep "$SLEEP_SECS"
    ((i++))
  done
  echo
  err "Timeout esperando $name en $host:$port"
  return 1
}

compose() {
  $DOCKER_COMPOSE_BIN -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
}

tail_if_fails() {
  local service="$1"
  log "Últimas líneas de logs para $service:"
  compose logs --tail=200 "$service" || true
}

validate_prometheus_targets() {
  log "Validando targets en Prometheus"
  # Espera endpoint de salud
  wait_http_ok "Prometheus" "$PROMETHEUS_URL" "/-/healthy" "200"

  # Cuenta targets 'up==1'
  local up_count total
  up_count="$(curl -fsS "${PROMETHEUS_URL}/api/v1/query?query=up" | jq '[.data.result[].value[1]|tonumber] | map(select(.==1)) | length' 2>/dev/null || echo 0)"
  total="$(curl -fsS "${PROMETHEUS_URL}/api/v1/targets" | jq '.data.activeTargets | length' 2>/dev/null || echo 0)"

  ok "Targets activos: ${up_count}/${total}"
  if [[ "$total" -eq 0 ]]; then
    err "Prometheus no tiene targets activos. Revisá 'scrape_configs' en prometheus.yml"
    return 1
  fi
  return 0
}

validate_alertmanager() {
  log "Validando Alertmanager"
  wait_http_ok "Alertmanager" "$ALERTMANAGER_URL" "/-/ready" "200"
  # Comprueba que cargó configuración
  wait_http_body_contains "Alertmanager" "$ALERTMANAGER_URL" "/api/v2/status" '"versionInfo"' || return 1
}

validate_grafana() {
  log "Validando Grafana"
  wait_http_ok "Grafana" "$GRAFANA_URL" "/api/health" "200"

  if [[ -n "$GRAFANA_ADMIN_USER" && -n "$GRAFANA_ADMIN_PASSWORD" ]]; then
    # Chequea que el server esté "ok" y (opcional) que haya al menos 1 datasource
    local health ds_count
    health="$(curl -fsS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${GRAFANA_URL}/api/health" | jq -r '.database')" || true
    if [[ "$health" != "ok" ]]; then
      err "Grafana database health != ok (valor: ${health:-n/a})"
      return 1
    fi
    ds_count="$(curl -fsS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${GRAFANA_URL}/api/datasources" | jq 'length' 2>/dev/null || echo 0)"
    ok "Grafana responde y tiene ${ds_count} datasource(s)"
  else
    log "Saltando validación de datasources (definí GRAFANA_ADMIN_USER/GRAFANA_ADMIN_PASSWORD para habilitarla)"
  fi
  return 0
}

print_summary() {
  cat <<EOF

================= RESUMEN =================
Stack:      $PROJECT_NAME
Compose:    $COMPOSE_FILE

URLs:
  • Prometheus:     $PROMETHEUS_URL  (/-/healthy, /targets, /graph)
  • Grafana:        $GRAFANA_URL     (/login, /api/health)
  • Alertmanager:   $ALERTMANAGER_URL (/-/ready, /#/alerts)

Comandos útiles:
  - Ver estado:       $DOCKER_COMPOSE_BIN -f $COMPOSE_FILE -p $PROJECT_NAME ps
  - Logs servicio:    $DOCKER_COMPOSE_BIN -f $COMPOSE_FILE -p $PROJECT_NAME logs -f <service>
  - Apagar stack:     $DOCKER_COMPOSE_BIN -f $COMPOSE_FILE -p $PROJECT_NAME down
===========================================
EOF
}

# ---------- Main ----------
main() {
  need docker
  need jq
  need curl
  load_dotenv

  log "Levantando stack con Docker Compose"
  compose pull || true
  compose up -d --remove-orphans

  log "Esperando servicios básicos"
  # Muchos exporters no exponen health; validamos a través de Prometheus
  validate_prometheus_targets || {
    tail_if_fails prometheus
    exit 1
  }

  # Grafana (opcional con credenciales)
  validate_grafana || {
    tail_if_fails grafana || true
    exit 1
  }

  # Alertmanager (si existe en el compose)
  if compose ps --services | grep -q '^alertmanager$'; then
    validate_alertmanager || {
      tail_if_fails alertmanager || true
      exit 1
    }
  else
    log "No se encontró servicio 'alertmanager' en el compose; omitiendo validación"
  fi

  print_summary
  ok "Stack listo y validado 🚀"
}

main "$@"
