#!/usr/bin/env bash
# Despliega desde los clones que ya viven en el servidor. Se corre AQUÍ, en el
# VPS, no desde tu máquina.
#
#   cd ~/portafolio/marketplace-deploy
#   bash scripts/server.sh            # todo: git pull, sitios y API
#   bash scripts/server.sh --web      # solo los dos sitios estáticos
#   bash scripts/server.sh --api      # solo la API
#   bash scripts/server.sh --nginx    # solo recargar nginx (necesita root)
#   bash scripts/server.sh --tls      # nginx y certificados (necesita root)
#   bash scripts/server.sh --seed     # siembra la demostración
#   bash scripts/server.sh --no-pull  # usa lo que ya está clonado
#
# Espera encontrar los otros repos cerca:
#   marketplace-deploy/   <- este
#   marketplace-back/
#   marketplace-front/
#   portafolio-v2/

set -euo pipefail

DEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(dirname "$DEPLOY")"

# Los clones pueden colgar del mismo nivel que este repo o de uno más arriba,
# según cómo se haya clonado. Se buscan en ambos antes de rendirse.
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

BACK="${BACK_DIR:-$(buscar marketplace-back || true)}"
FRONT="${FRONT_DIR:-$(buscar marketplace-front || true)}"
PORTAFOLIO="${PORTAFOLIO_DIR:-$(buscar portafolio-v2 || true)}"

PORTFOLIO_DOMAIN="${PORTFOLIO_DOMAIN:-alfredomejia.com.mx}"
DEMO_WEB="${DEMO_WEB:-https://demo.alfredomejia.com.mx}"
# La API se sirve bajo el mismo host del demo. api.veloce-ts.com es de otro
# proyecto y no se toca.
DEMO_API="${DEMO_API:-https://demo.alfredomejia.com.mx}"
EMAIL="${CERT_EMAIL:-mejia_alfredo@outlook.com}"

COMPOSE=(docker compose --env-file "$BACK/.env" -f "$DEPLOY/docker-compose.prod.yml")

do_web=false do_api=false do_tls=false do_seed=false do_nginx=false do_pull=true
if [ $# -eq 0 ]; then
  do_web=true; do_api=true
fi
for arg in "$@"; do
  case "$arg" in
    --web)     do_web=true ;;
    --api)     do_api=true ;;
    --tls)     do_tls=true; do_nginx=true ;;
    --nginx)   do_nginx=true ;;
    --seed)    do_seed=true ;;
    --all)     do_web=true; do_api=true ;;
    --no-pull) do_pull=false ;;
    *) echo "opción desconocida: $arg"; exit 1 ;;
  esac
done

say() { printf '\n==> %s\n' "$1"; }

falta() {
  echo "No encontré el repo $1 cerca de $DEPLOY."
  echo "Busqué en:"
  echo "  $BASE/$1"
  echo "  $(dirname "$BASE")/$1"
  echo "  $BASE/marketplace/$1"
  echo "Si está en otro lado, pásalo así:"
  echo "  BACK_DIR=/ruta/marketplace-back FRONT_DIR=... PORTAFOLIO_DIR=... bash $0 $*"
  exit 1
}

[ -n "$BACK" ] && [ -d "$BACK" ] || falta marketplace-back
[ -n "$FRONT" ] && [ -d "$FRONT" ] || falta marketplace-front
[ -n "$PORTAFOLIO" ] && [ -d "$PORTAFOLIO" ] || falta portafolio-v2

# Las lee docker-compose.prod.yml, que vive en este repo y no sabe dónde
# clonaron el del backend.
export BACK_CONTEXT="$BACK"
export DEPLOY_DIR="$DEPLOY"

echo "repos:"
printf '  %-14s %s\n' deploy "$DEPLOY" back "$BACK" front "$FRONT" portafolio "$PORTAFOLIO"

if ! command -v bun >/dev/null 2>&1; then
  echo "Falta bun. Instálalo con: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

if $do_pull; then
  say "trayendo lo último de GitHub"
  for repo in "$DEPLOY" "$BACK" "$FRONT" "$PORTAFOLIO"; do
    printf '  %-22s ' "$(basename "$repo")"
    git -C "$repo" pull --ff-only --quiet && echo "$(git -C "$repo" rev-parse --short HEAD)"
  done
fi

if $do_web; then
  # --bun obliga a que los binarios de node_modules corran con bun y no con el
  # node del sistema. Sin esto, astro y vite siguen su shebang hacia node, y si
  # el del servidor es viejo, el build muere aunque bun esté al día.
  # NODE_ENV=development a proposito: con production, bun se salta las
  # devDependencies, y ahi viven typescript y los @types. El build las necesita
  # aunque el resultado sea estatico.
  #
  # Sin --silent: si una dependencia no se instala, quiero verlo aqui y no
  # veinte lineas despues disfrazado de error de tipos.
  say "construyendo el portafolio"
  ( cd "$PORTAFOLIO" && NODE_ENV=development bun install --frozen-lockfile &&
    PUBLIC_DEMO_API="$DEMO_API" PUBLIC_DEMO_WEB="$DEMO_WEB" bun --bun run build )

  say "construyendo el frontend del marketplace"
  ( cd "$FRONT" && NODE_ENV=development bun install --frozen-lockfile &&
    bun --bun run build )

  say "publicando los sitios"
  sudo mkdir -p /var/www/portafolio /var/www/marketplace
  sudo rsync -a --delete "$PORTAFOLIO/dist/" /var/www/portafolio/ 2>/dev/null ||
    { sudo rm -rf /var/www/portafolio/*; sudo cp -r "$PORTAFOLIO/dist/." /var/www/portafolio/; }
  sudo rsync -a --delete "$FRONT/dist/" /var/www/marketplace/ 2>/dev/null ||
    { sudo rm -rf /var/www/marketplace/*; sudo cp -r "$FRONT/dist/." /var/www/marketplace/; }
  echo "  portafolio:  $(find /var/www/portafolio -type f | wc -l) archivos"
  echo "  marketplace: $(find /var/www/marketplace -type f | wc -l) archivos"
fi

if $do_api; then
  [ -f "$BACK/.env" ]     || { echo "Falta $BACK/.env (usuario y contraseña de Postgres). Lo genera bootstrap.sh."; exit 1; }
  [ -f "$BACK/api.env" ]  || { echo "Falta $BACK/api.env (secretos de la API). Lo genera bootstrap.sh."; exit 1; }

  say "levantando los contenedores"
  "${COMPOSE[@]}" build api
  "${COMPOSE[@]}" up -d

  say "esperando a que la API responda"
  for i in $(seq 1 30); do
    if curl -fsS -m 5 http://127.0.0.1:3102/health/ready >/dev/null 2>&1; then
      echo "  lista"
      break
    fi
    [ "$i" -eq 30 ] && { echo "  no respondió; mira los logs con: ${COMPOSE[*]} logs api"; exit 1; }
    sleep 2
  done

  say "migraciones"
  "${COMPOSE[@]}" exec -T api bun run db:migrate
fi

if $do_nginx; then
  [ "$(id -u)" -eq 0 ] || { echo "Esto necesita root. Corre: sudo -E bash scripts/server.sh $*"; exit 1; }

  say "nginx"
  cp "$DEPLOY"/nginx/*.conf /etc/nginx/sites-available/
  for site in portafolio marketplace; do
    ln -sf "/etc/nginx/sites-available/$site.conf" "/etc/nginx/sites-enabled/$site.conf"
  done
  nginx -t
  systemctl reload nginx

  # Copiar las plantillas pisa lo que certbot escribio en esos archivos: los
  # bloques de 443 con las rutas de los certificados. Sin esto, nginx se queda
  # sin HTTPS para estos nombres y acaba presentando el certificado de otro
  # sitio del servidor.
  #
  # `certbot install` no habla con Let's Encrypt: reinstala un certificado que
  # ya existe, asi que no gasta intentos contra el limite.
  for cert in "$PORTFOLIO_DOMAIN" demo.alfredomejia.com.mx; do
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: $cert"; then
      echo "  reinstalando el certificado de $cert"
      certbot install --nginx --cert-name "$cert" --non-interactive --redirect >/dev/null
    else
      echo "  sin certificado para $cert todavia (corre --tls)"
    fi
  done

  nginx -t
  systemctl reload nginx
  echo "  configuracion recargada"
fi

if $do_tls; then
  say "certificados"
  # Un certificado por sitio, y solo para los nombres que apuntan AQUÍ. No
  # basta con que resuelvan: un dominio recién comprado resuelve al parking
  # del registrador, y el reto se serviría desde otra máquina.
  MI_IP=$(curl -sS -m 10 https://api.ipify.org || hostname -I | awk '{print $1}')
  echo "  este servidor es $MI_IP"

  resuelve() {
    local ips
    ips=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -n "$ips" ] || return 1
    echo "$ips" | grep -qx "$MI_IP"
  }

  emitir() {
    local args=()
    for host in "$@"; do
      if resuelve "$host"; then
        args+=(-d "$host")
      else
        echo "  saltando $host: todavía no apunta a este servidor"
      fi
    done
    [ ${#args[@]} -gt 0 ] || { echo "  nada que certificar"; return 0; }
    certbot --nginx --non-interactive --agree-tos --redirect -m "$EMAIL" "${args[@]}"
  }

  emitir "$PORTFOLIO_DOMAIN" "www.$PORTFOLIO_DOMAIN"
  emitir demo.alfredomejia.com.mx

  nginx -t
  systemctl reload nginx
fi

if $do_seed; then
  say "sembrando la demostración"
  "${COMPOSE[@]}" exec -T api bun run demo:seed
fi

say "comprobando"
for url in "https://$PORTFOLIO_DOMAIN/" "$DEMO_WEB/" "$DEMO_WEB/api/categories"; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 "$url" 2>/dev/null || true)
  printf '  %-45s %s\n' "$url" "${code:-000}"
done

echo
echo "Listo."
