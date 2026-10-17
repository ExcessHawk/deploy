# deploy

El despliegue de todos los proyectos que viven en el VPS. Repo aparte a
propósito: la infraestructura no tiene por qué ensuciar el repositorio de cada
aplicación, y así el despliegue tiene su propio historial.

```
deploy/
  scripts/
    bootstrap.sh              prepara el VPS, una sola vez
    server.sh                 despliega uno o todos los proyectos
  proyectos/
    00-portafolio/
      proyecto.env            qué es, dónde vive, cómo se construye
      nginx/portafolio.conf
    02-marketplace/
      proyecto.env
      docker-compose.prod.yml
      Dockerfile.api
      api.env.example
      nginx/marketplace.conf
      cron/marketplace-demo
```

## Cómo se usa

```bash
bash scripts/server.sh                      # todos los proyectos
bash scripts/server.sh 02-marketplace       # solo uno
bash scripts/server.sh 02-marketplace --api # solo su API
```

| Bandera | Qué hace |
|---|---|
| `--web` | Construye el frontend y lo publica en su carpeta |
| `--api` | Construye la imagen, levanta los contenedores y migra |
| `--nginx` | Copia la configuración y recarga. Necesita root |
| `--tls` | Lo anterior más pedir certificados. Necesita root |
| `--seed` | Siembra la demostración |
| `--cron` | Instala el reinicio por hora. Necesita root |
| `--no-pull` | Usa lo que ya está clonado |

Sin banderas hace `--web` y `--api`.

## Cómo está acomodado en el servidor

```
~/portafolio/
  deploy/               <- este repo
  portafolio-v2/
  marketplace/
    marketplace-back/
    marketplace-front/
```

Los scripts buscan cada repo por su nombre en cuatro lugares: al lado de este,
dentro de una carpeta intermedia, un nivel arriba, o esa misma combinación. La
anidación de arriba no estorba.

## Agregar un proyecto nuevo

Crea `proyectos/<slug>/proyecto.env`. El script no se toca.

```bash
NOMBRE="Helpdesk"
HOST=soporte.alfredomejia.com.mx

WEB_REPO=helpdesk-front          # el repo, tal como se llama en GitHub
WEB_ROOT=/var/www/helpdesk
WEB_BUILD_ENV=""                 # variables que necesite su build

API_REPO=helpdesk-back           # vacío si es un sitio estático
API_CONTAINER=helpdesk_api
API_PORT=3103
COMPOSE=docker-compose.prod.yml

SEED_CMD="bun run demo:seed"
REFRESH_CMD="bun run demo:refresh"

NGINX_CONF=nginx/helpdesk.conf
CRON_FILE=cron/helpdesk-demo
```

Junto a eso van su `docker-compose.prod.yml`, su `Dockerfile.api`, su
`api.env.example` y su configuración de nginx. Lo más rápido es copiar la
carpeta de `02-marketplace` y cambiar nombres, puertos y dominio.

El compose recibe por variable dónde está el código, porque desde aquí no hay
forma de saberlo:

```yaml
context: ${BACK_CONTEXT:?falta BACK_CONTEXT}
dockerfile: ${DEPLOY_DIR:?falta DEPLOY_DIR}/Dockerfile.api
```

`server.sh` las exporta después de localizar los repos.

Los puertos salen de `00-base/PLANTILLA.md` en el repo de planeación: 3101 a
3109 para las APIs y 5441 a 5449 para Postgres. Todo publica **solo en
127.0.0.1**; nginx es la única puerta.

## Primera vez en un servidor nuevo

```bash
cd ~/portafolio
git clone https://github.com/ExcessHawk/deploy.git
cd deploy
bash scripts/bootstrap.sh
```

Instala Docker, bun, nginx, certbot, ufw y fail2ban, crea el usuario `deploy` y
genera los secretos de cada proyecto que tenga backend, junto a su código, con
permisos 600.

Para entrar luego como `deploy` desde otra máquina hay que darle una llave:

```bash
AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" bash scripts/bootstrap.sh
```

El firewall queda con **22, 80 y 443 abiertos y lo demás cerrado**. Se permite
el 22 *antes* de encenderlo, así que no te saca.

Después:

```bash
bash scripts/server.sh
sudo -E bash scripts/server.sh --tls
bash scripts/server.sh --seed
sudo -E bash scripts/server.sh --cron
```

## Lo que hay que tener claro

**Los secretos se generan en el servidor.** No hay ninguno en este repo;
`api.env.example` es la plantilla con los campos vacíos. `bootstrap.sh` la copia
rellenando solo lo que está en blanco, para no perder variables que el proyecto
necesite.

**`DEMO_MODE=true` entrega sesiones sin contraseña.** Es un bypass puesto a
propósito, con cuatro candados descritos en el README de cada proyecto. **Esas
bases nunca deben tener datos de personas reales**: la cuenta de administrador
de una demostración es administradora de verdad dentro de ella.

**`frame-ancestors` es lo que permite el iframe** del playground.
`X-Frame-Options` no sirve: su `allow-from` está muerto en los navegadores
modernos. Y ojo, la cabecera *restringe*; si falta, cualquiera puede embeber el
demo.

**Nginx no hereda las cabeceras** en un `location` que tenga las suyas. La
página cae por `try_files` en `location = /index.html`; si ese bloque trae un
`Cache-Control`, pierde todo lo demás. Hay que repetirlas ahí. Los assets sí las
traen, lo que hace el fallo difícil de ver.

**Certbot escribe dentro de estas mismas plantillas.** Copiarlas encima borra el
TLS y el sitio empieza a presentar el certificado de otro. Por eso `--nginx`
reinstala los certificados después de copiar, con `certbot install`, que no
habla con Let's Encrypt y no gasta intentos.

**Un certificado por sitio, y solo si el nombre apunta aquí.** No basta con que
resuelva: un dominio recién comprado resuelve al parking del registrador, el
reto se sirve desde otra máquina y falla igual.

**Verifica el DNS contra un resolver público**, nunca contra el panel del
registrador:

```bash
curl -s "https://dns.google/resolve?name=NOMBRE&type=A" | grep -o '"data":"[^"]*"'
```

## Si algo sale mal

```bash
docker ps                                   # qué está corriendo
docker logs -f --tail 100 marketplace_api   # logs de una API
sudo nginx -t                               # la configuración es válida
sudo tail -50 /var/log/nginx/error.log
sudo certbot certificates                   # qué certificados hay
```
