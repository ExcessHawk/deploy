#!/usr/bin/env bash
# Prepara el VPS desde cero. Se corre UNA vez, como root, desde el repo:
#
#   cd ~/portafolio/marketplace-deploy
#   bash scripts/bootstrap.sh
#
# Deja instalado Docker, bun, nginx, certbot, ufw y fail2ban, y genera los
# secretos. No despliega nada: eso es server.sh.

set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
# Los secretos de cada proyecto viven junto a su backend. Este script esta en
# otro repo, asi que los busca cerca en vez de adivinar rutas.
DEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(dirname "$DEPLOY")"

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

WEB_DIR=/var/www

echo "despliegue: $DEPLOY"

echo "==> paquetes base"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg rsync ufw fail2ban nginx

echo "==> Docker"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "==> bun"
# Los lockfiles de este proyecto son de bun 1.4. Un bun 1.3 no sabe leerlos:
# los ignora y vuelve a resolver, que es justo lo que un lockfile evita.
BUN_MIN_MAJOR=1
BUN_MIN_MINOR=4
bun_viejo() {
  command -v bun >/dev/null 2>&1 || return 0
  local v major minor
  v=$(bun --version 2>/dev/null) || return 0
  major=${v%%.*}
  minor=$(echo "$v" | cut -d. -f2)
  [ "$major" -lt "$BUN_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$BUN_MIN_MAJOR" ] && [ "$minor" -lt "$BUN_MIN_MINOR" ] && return 0
  return 1
}

if bun_viejo; then
  echo "    instalando o actualizando bun"
  curl -fsSL https://bun.sh/install | bash
  for candidate in "$HOME/.bun/bin/bun" /root/.bun/bin/bun; do
    [ -x "$candidate" ] && ln -sf "$candidate" /usr/local/bin/bun && break
  done
  hash -r
fi
echo "    bun $(bun --version)"
if bun_viejo; then
  echo "    !! sigue siendo anterior a 1.4; los lockfiles se van a resolver de nuevo"
fi

echo "==> certbot"
apt-get install -y -qq certbot python3-certbot-nginx

echo "==> usuario deploy"
# Opcional. Si vas a desplegar entrando como root al servidor, no lo necesitas:
# server.sh corre con quien lo invoque. Sirve si prefieres un usuario aparte,
# sin contraseña y solo con llave. Para darle una:
#   AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" bash scripts/bootstrap.sh
AUTHORIZED_KEY="${AUTHORIZED_KEY:-}"

if ! id deploy >/dev/null 2>&1; then
  adduser --disabled-password --gecos '' deploy
  usermod -aG docker deploy
fi

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -d -m 700 /root/.ssh

if [ -n "$AUTHORIZED_KEY" ]; then
  for f in /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys; do
    touch "$f"
    grep -qxF "$AUTHORIZED_KEY" "$f" || echo "$AUTHORIZED_KEY" >> "$f"
    chmod 600 "$f"
  done
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  echo "    llave instalada para root y deploy"
elif [ -s /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  chmod 600 /home/deploy/.ssh/authorized_keys
  echo "    deploy hereda las llaves de root"
else
  echo "    sin llave: el usuario deploy queda creado pero no se puede entrar con él"
  echo "    (no estorba; si despliegas como root, no hace falta)"
fi

echo "==> carpetas"
for env in "$DEPLOY"/proyectos/*/proyecto.env; do
  WEB_ROOT=""
  # shellcheck disable=SC1090
  . "$env"
  [ -n "$WEB_ROOT" ] || continue
  mkdir -p "$WEB_ROOT"
  chown -R deploy:deploy "$WEB_ROOT"
  echo "    $WEB_ROOT"
done

echo "==> secretos"
# Uno por proyecto que tenga backend. Se generan aqui y nunca se versionan.
for env in "$DEPLOY"/proyectos/*/proyecto.env; do
  slug=$(basename "$(dirname "$env")")
  NOMBRE="" HOST="" API_REPO="" API_PORT="" WEB_ROOT=""
  # shellcheck disable=SC1090
  . "$env"
  [ -n "$API_REPO" ] || continue

  destino="$(buscar "$API_REPO" || true)"
  if [ -z "$destino" ]; then
    echo "    $slug: no encontre el repo $API_REPO, lo salto"
    continue
  fi

  plantilla="$DEPLOY/proyectos/$slug/api.env.example"
  if [ ! -f "$destino/api.env" ]; then
    umask 077
    if [ -f "$plantilla" ]; then
      # Se parte de la plantilla del proyecto y solo se rellenan los secretos
      # vacios, para no perder ninguna variable que el proyecto necesite.
      {
        sed -e "s|^JWT_SECRET=$|JWT_SECRET=$(openssl rand -base64 48)|" \
            -e "s|^JWT_REFRESH_SECRET=$|JWT_REFRESH_SECRET=$(openssl rand -base64 48)|" \
            -e "s|^PAYMENT_WEBHOOK_SECRET=$|PAYMENT_WEBHOOK_SECRET=$(openssl rand -base64 36)|" \
            "$plantilla"
      } > "$destino/api.env"
    else
      # Antes aquí se inventaba una plantilla mínima. Era peor que fallar: el
      # archivo salía con buena cara y sin DEMO_MODE ni CORS_ORIGINS, y el
      # error aparecía mucho después, disfrazado de otra cosa.
      echo "    $slug: falta proyectos/$slug/api.env.example"
      echo "         No invento uno: cada proyecto necesita sus propias variables."
      exit 1
    fi
    chown deploy:deploy "$destino/api.env"
    chmod 600 "$destino/api.env"
    echo "    $slug: api.env generado"
  else
    echo "    $slug: api.env ya existia, no lo toco"
  fi

  if [ ! -f "$destino/.env" ]; then
    umask 077
    cat > "$destino/.env" <<EOF
POSTGRES_USER=${slug##*-}
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)
POSTGRES_DB=${slug##*-}
EOF
    chown deploy:deploy "$destino/.env"
    chmod 600 "$destino/.env"
    echo "    $slug: .env de Postgres generado"
  fi
done

echo "==> firewall"
# Importante: se permite SSH ANTES de encender ufw, o te quedas fuera.
ufw allow "$SSH_PORT"/tcp comment 'ssh'
ufw allow 80/tcp  comment 'http'
ufw allow 443/tcp comment 'https'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status verbose

systemctl enable --now fail2ban

echo "==> nginx arriba, sin sitios todavía"
rm -f /etc/nginx/sites-enabled/default
systemctl enable --now nginx

echo
echo "Listo. Los secretos quedaron junto al backend de cada proyecto,"
echo "en sus archivos .env y api.env, con permisos 600."
echo
echo "Lo que sigue, desde este repo:"
echo "  bash scripts/server.sh"
echo "  sudo -E bash scripts/server.sh --tls"
echo "  bash scripts/server.sh --seed"
