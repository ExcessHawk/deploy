#!/usr/bin/env bash
# Despliega desde los clones que viven en el servidor. Se corre AQUÍ, en el VPS.
#
#   bash scripts/server.sh                      todos los proyectos
#   bash scripts/server.sh 02-marketplace       solo uno
#   bash scripts/server.sh 02-marketplace --api solo su API
#
# Banderas:
#   --web       construye y publica los sitios estáticos
#   --api       construye la imagen, levanta los contenedores y migra
#   --nginx     copia la configuración y recarga (necesita root)
#   --tls       lo anterior más pedir certificados (necesita root)
#   --seed      siembra la demostración
#   --cron      instala el reinicio por hora
#   --no-pull   usa lo que ya está clonado
#
# Sin banderas hace --web y --api.
#
# Cada proyecto se describe en proyectos/<slug>/proyecto.env. Agregar uno nuevo
# es crear esa carpeta; este script no se toca.

set -euo pipefail

DEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(dirname "$DEPLOY")"
CERT_EMAIL="${CERT_EMAIL:-mejia_alfredo@outlook.com}"

say()  { printf '\n==> %s\n' "$1"; }
paso() { printf '  %s\n' "$1"; }

# Los repos de código pueden colgar del mismo nivel que este, de uno más
# arriba, o de una carpeta intermedia. Se busca en todos antes de rendirse.
buscar() {
  local nombre="$1" dir
  local candidatos=(
    "$BASE/$nombre"
    "$BASE/marketplace/$nombre"
    "$(dirname "$BASE")/$nombre"
    "$(dirname "$BASE")/marketplace/$nombre"
  )
  for dir in "${candidatos[@]}"; do
    [ -d "$dir" ] && { echo "$dir"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- argumentos

proyectos=()
do_web=false do_api=false do_nginx=false do_tls=false do_seed=false do_cron=false do_pull=true
hubo_bandera=false

for arg in "$@"; do
  case "$arg" in
    --web)     do_web=true;   hubo_bandera=true ;;
    --api)     do_api=true;   hubo_bandera=true ;;
    --nginx)   do_nginx=true; hubo_bandera=true ;;
    --tls)     do_tls=true; do_nginx=true; hubo_bandera=true ;;
    --seed)    do_seed=true;  hubo_bandera=true ;;
    --cron)    do_cron=true;  hubo_bandera=true ;;
    --all)     do_web=true; do_api=true; hubo_bandera=true ;;
    --no-pull) do_pull=false ;;
    --*)       echo "opción desconocida: $arg"; exit 1 ;;
    *)         proyectos+=("$arg") ;;
  esac
done

$hubo_bandera || { do_web=true; do_api=true; }

if [ ${#proyectos[@]} -eq 0 ]; then
  for dir in "$DEPLOY"/proyectos/*/; do
    [ -f "$dir/proyecto.env" ] && proyectos+=("$(basename "$dir")")
  done
fi

if $do_nginx || $do_tls || $do_cron; then
  [ "$(id -u)" -eq 0 ] || { echo "Eso necesita root: sudo -E bash $0 $*"; exit 1; }
fi

if $do_web && ! command -v bun >/dev/null 2>&1; then
  echo "Falta bun. Lo instala bootstrap.sh, o: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

say "despliegue: $DEPLOY"
paso "proyectos: ${proyectos[*]}"

if $do_pull; then
  paso "actualizando el despliegue: $(git -C "$DEPLOY" pull --ff-only --quiet && git -C "$DEPLOY" rev-parse --short HEAD)"
fi

# ------------------------------------------------------------------- certbot

MI_IP=""
apunta_aqui() {
  [ -n "$MI_IP" ] || MI_IP=$(curl -sS -m 10 https://api.ipify.org || hostname -I | awk '{print $1}')
  local ips
  ips=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  [ -n "$ips" ] || return 1
  echo "$ips" | grep -qx "$MI_IP"
}

# ----------------------------------------------------------------- proyectos

for slug in "${proyectos[@]}"; do
  carpeta="$DEPLOY/proyectos/$slug"
  [ -f "$carpeta/proyecto.env" ] || { echo "No existe proyectos/$slug/proyecto.env"; exit 1; }

  NOMBRE="" HOST="" ALIAS="" WEB_REPO="" WEB_ROOT="" WEB_BUILD_ENV=""
  API_REPO="" API_CONTAINER="" API_PORT="" COMPOSE=""
  SEED_CMD="" REFRESH_CMD="" NGINX_CONF="" CRON_FILE=""
  # shellcheck disable=SC1090
  . "$carpeta/proyecto.env"

  say "$NOMBRE ($slug)"

  WEB_DIR=""
  if [ -n "$WEB_REPO" ]; then
    WEB_DIR="$(buscar "$WEB_REPO" || true)"
    [ -n "$WEB_DIR" ] || { echo "  no encontré el repo $WEB_REPO"; exit 1; }
    paso "web: $WEB_DIR"
  fi

  API_DIR=""
  if [ -n "$API_REPO" ]; then
    API_DIR="$(buscar "$API_REPO" || true)"
    [ -n "$API_DIR" ] || { echo "  no encontré el repo $API_REPO"; exit 1; }
    paso "api: $API_DIR"
  fi

  if $do_pull; then
    # Un proyecto puede tener su backend y su frontend en subcarpetas del mismo
    # clon, así que se trae por repositorio y no por carpeta: si no, se haría
    # el mismo pull dos veces.
    tirados=()
    for dir in "$WEB_DIR" "$API_DIR"; do
      [ -n "$dir" ] || continue
      raiz=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
        paso "$(basename "$dir") no es un repositorio, lo dejo como está"
        continue
      }
      ya=false
      for visto in "${tirados[@]:-}"; do
        [ "$visto" = "$raiz" ] && ya=true && break
      done
      $ya && continue
      tirados+=("$raiz")
      git -C "$raiz" pull --ff-only --quiet
      paso "$(basename "$raiz") en $(git -C "$raiz" rev-parse --short HEAD)"
    done
  fi

  compose=()
  if [ -n "$COMPOSE" ] && [ -n "$API_DIR" ]; then
    export BACK_CONTEXT="$API_DIR" DEPLOY_DIR="$carpeta"
    compose=(docker compose --env-file "$API_DIR/.env" -f "$carpeta/$COMPOSE")
  fi

  if $do_web && [ -n "$WEB_DIR" ]; then
    paso "construyendo"
    # NODE_ENV=development a propósito: con production, bun se salta las
    # devDependencies, donde viven typescript y los @types.
    #
    # --bun obliga a que astro y vite corran dentro de bun. Sin eso siguen su
    # shebang hacia el node del sistema, que puede ser viejo.
    ( cd "$WEB_DIR" && NODE_ENV=development bun install --frozen-lockfile &&
      env $WEB_BUILD_ENV bun --bun run build )

    paso "publicando en $WEB_ROOT"
    mkdir -p "$WEB_ROOT"
    rm -rf "${WEB_ROOT:?}"/*
    cp -r "$WEB_DIR/dist/." "$WEB_ROOT/"
    paso "$(find "$WEB_ROOT" -type f | wc -l) archivos"
  fi

  if $do_api && [ ${#compose[@]} -gt 0 ]; then
    [ -f "$API_DIR/.env" ]    || { echo "  falta $API_DIR/.env (lo genera bootstrap.sh)"; exit 1; }
    [ -f "$API_DIR/api.env" ] || { echo "  falta $API_DIR/api.env (lo genera bootstrap.sh)"; exit 1; }

    paso "levantando contenedores"
    "${compose[@]}" build api
    "${compose[@]}" up -d

    paso "esperando a la API"
    for i in $(seq 1 30); do
      curl -fsS -m 5 "http://127.0.0.1:${API_PORT}/health/ready" >/dev/null 2>&1 && { paso "lista"; break; }
      [ "$i" -eq 30 ] && { echo "  no respondió; mira: docker logs $API_CONTAINER"; exit 1; }
      sleep 2
    done

    paso "migraciones"
    "${compose[@]}" exec -T api bun run db:migrate
  fi

  if $do_nginx && [ -n "$NGINX_CONF" ]; then
    destino="/etc/nginx/sites-available/$slug.conf"
    cp "$carpeta/$NGINX_CONF" "$destino"
    ln -sf "$destino" "/etc/nginx/sites-enabled/$slug.conf"
    paso "nginx: $slug.conf"
  fi

  if $do_tls && [ -n "$HOST" ]; then
    args=()
    for host in $HOST $ALIAS; do
      if apunta_aqui "$host"; then
        args+=(-d "$host")
      else
        paso "saltando $host: no apunta a este servidor"
      fi
    done
    if [ ${#args[@]} -gt 0 ]; then
      certbot --nginx --non-interactive --agree-tos --redirect -m "$CERT_EMAIL" "${args[@]}"
      paso "certificado emitido"
    fi
  fi

  if $do_seed && [ -n "$SEED_CMD" ] && [ ${#compose[@]} -gt 0 ]; then
    paso "sembrando"
    "${compose[@]}" exec -T api $SEED_CMD
  fi

  if $do_cron && [ -n "$CRON_FILE" ]; then
    cp "$carpeta/$CRON_FILE" "/etc/cron.d/$slug"
    chmod 644 "/etc/cron.d/$slug"
    paso "cron instalado"
  fi
done

# ---------------------------------------------------------- nginx y chequeos

if $do_nginx; then
  nginx -t
  systemctl reload nginx

  # Copiar las plantillas pisa lo que certbot escribió en esos archivos: los
  # bloques de 443 con las rutas de los certificados. Sin esto, nginx se queda
  # sin HTTPS y acaba presentando el certificado de otro sitio.
  #
  # `certbot install` no habla con Let's Encrypt: reinstala uno que ya existe,
  # así que no gasta intentos contra el límite.
  say "reinstalando certificados"
  for slug in "${proyectos[@]}"; do
    HOST=""
    # shellcheck disable=SC1090
    . "$DEPLOY/proyectos/$slug/proyecto.env"
    [ -n "$HOST" ] || continue
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: $HOST"; then
      certbot install --nginx --cert-name "$HOST" --non-interactive --redirect >/dev/null
      paso "$HOST"
    else
      paso "$HOST: sin certificado todavía (corre --tls)"
    fi
  done

  nginx -t
  systemctl reload nginx
fi

say "comprobando"
for slug in "${proyectos[@]}"; do
  HOST=""
  # shellcheck disable=SC1090
  . "$DEPLOY/proyectos/$slug/proyecto.env"
  [ -n "$HOST" ] || continue
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 "https://$HOST/" 2>/dev/null || true)
  printf '  %-34s %s\n' "$HOST" "${code:-000}"
done

echo
echo "Listo."
