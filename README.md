# marketplace-deploy

Lo que vive en el VPS y cómo ponerlo ahí. Repo aparte a propósito: la
infraestructura no tiene por qué ensuciar el repositorio de la aplicación, y así
el despliegue tiene su propio historial.

## Qué va y qué no

| Pieza | Dónde | Por qué |
|---|---|---|
| Portafolio | VPS, nginx, estático | 343 KB. Podría ir en Netlify, pero tenerlo en el mismo nginx deja un solo certificado y un solo lugar donde tocar cabeceras |
| Frontend del marketplace | VPS, nginx, estático | Mismo origen que la API, así el demo no necesita CORS |
| API del marketplace | VPS, Docker | Bun, necesita proceso vivo y WebSocket |
| Postgres + Redis | VPS, Docker | Solo escuchan en 127.0.0.1 |
| `veloce-ts.com` y `docs.` | **Netlify, sin tocar** | Ya funcionan |
| SaaS, citas médicas, gpu-hunter | **No se suben** | Privado, a medias y sin interfaz web |

## Mapa de dominios

```
alfredomejia.com.mx        → /var/www/portafolio
www.alfredomejia.com.mx    → lo mismo
demo.alfredomejia.com.mx   → /var/www/marketplace + /api + /ws al contenedor
```

Los tres ya resuelven a `2.25.75.147`.

`api.veloce-ts.com` **no es de este proyecto**: es la API de Pensum y vive en el
mismo servidor. No la toques desde aquí. La API del marketplace se sirve bajo
`demo.alfredomejia.com.mx/api`, mismo origen que su frontend, que de paso le
ahorra el CORS.

**El DNS de `veloce-ts.com` lo lleva Netlify**, no Hostinger: sus nameservers
son `dns1–4.p09.nsone.net`, el pool de NS1 que usa Netlify. Hostinger todavía
guarda una copia vieja de esa zona en su panel, de antes de la mudanza, y esa
copia **no la consulta nadie**. Por eso un registro agregado ahí aparece en el
panel y nunca resuelve: le pasó a `marketplace` y le pasa a `vps`, que el panel
lista apuntando a `82.197.93.101` y en DNS público no existe.
`api.veloce-ts.com` sí funciona porque ese registro vive en la zona de Netlify.

Para tocar `veloce-ts.com` hay que hacerlo **en Netlify**. El demo vive bajo
`alfredomejia.com.mx` justamente para no depender de eso: esa zona sí la lleva
Hostinger y publica en menos de un minuto.

Comprueba siempre contra DNS público, nunca contra el panel:

```bash
curl -s "https://dns.google/resolve?name=NOMBRE&type=A" | grep -o '"data":"[^"]*"'
```

## Cómo está acomodado en el servidor

Los tres repos clonados, uno al lado del otro:

```
~/portafolio/
  marketplace-deploy/   <- este repo
  portafolio-v2/
  marketplace/
    marketplace-back/
    marketplace-front/
```

Los scripts buscan los otros tres cerca, así que esa anidación extra no estorba.
Si los mueves, `BACK_DIR=`, `FRONT_DIR=` y `PORTAFOLIO_DIR=` los reubican.

Los contratos de Zod no son una carpeta: se instalan desde
[marketplace-contracts](https://github.com/ExcessHawk/marketplace-contracts),
así que el build de la imagen necesita red.

## Pasos

### 1. Una sola vez

```bash
ssh root@2.25.75.147 "AUTHORIZED_KEY='$(cat ~/.ssh/id_ed25519.pub)' bash -s"   < marketplace-deploy/scripts/bootstrap.sh
```

Instala Docker, nginx, certbot, bun, ufw y fail2ban, crea el usuario `deploy` y
genera los secretos en `.env` y `api.env` dentro del repo del backend.

Si no pasas `AUTHORIZED_KEY` y root no tiene llaves, te avisa: el usuario
`deploy` no tiene contraseña y nadie podría entrar con él.

El firewall queda con **22, 80 y 443 abiertos y lo demás cerrado**. Postgres y
Redis no se publican: solo escuchan en 127.0.0.1.

### 2. Desplegar, desde el servidor

```bash
cd ~/portafolio/marketplace-deploy
bash scripts/server.sh            # git pull, construye los sitios, levanta la API
sudo -E bash scripts/server.sh --tls
bash scripts/server.sh --seed
```

Y el cron del reinicio:

```bash
sudo cp cron/marketplace-demo /etc/cron.d/marketplace-demo
```

### 3. Cada cambio posterior

```bash
cd ~/portafolio/marketplace-deploy && bash scripts/server.sh
```

Hace `git pull` en los tres repos y reconstruye lo que toque. Con `--web` o
`--api` limitas a una parte, y con `--no-pull` usas lo que ya está clonado.

## Nginx y certbot se pisan

Las plantillas de `deploy/nginx/` solo traen el bloque de HTTP. Los de HTTPS los
escribe certbot dentro de esos mismos archivos cuando emite un certificado, asi
que **copiar las plantillas borra la configuracion de TLS**. El sintoma es feo y
despista: el sitio deja de presentar su certificado y empieza a ofrecer el de
otro sitio del servidor, y el navegador habla de "nombre de entidad incorrecto".

Por eso `--nginx` vuelve a instalar los certificados despues de copiar. Se usa
`certbot install`, que **no** habla con Let's Encrypt: solo mete en nginx uno que
ya existe. Si algun dia hay que repararlo a mano:

```bash
sudo certbot certificates                      # ver los nombres
sudo certbot install --nginx --cert-name alfredomejia.com.mx --non-interactive --redirect
sudo nginx -t && sudo systemctl reload nginx
```

## Lo que hay que tener claro

**`DEMO_MODE=true` en este servidor.** `POST /api/demo/session` entrega sesiones
sin contraseña. Esa base no debe tener jamás datos de personas reales: la cuenta
de administrador de la demostración es administradora de verdad dentro de ella.
Los cuatro candados están descritos en el README del marketplace.

**`frame-ancestors` es lo que permite el iframe.** Está en
`nginx/marketplace.conf` y nombra al portafolio explícitamente. Si cambias el
dominio del portafolio, hay que cambiarlo ahí también o el playground sale en
blanco.

**`CORS_ORIGINS` tiene que incluir el portafolio**, o la consola de API del
playground muere en CORS. Está en `api.env`.

**`TRUST_PROXY_HOPS=1`.** Detrás de nginx la IP del visitante llega en
`X-Forwarded-For`. Sin esto, el limitador de peticiones mete a todo internet en
el mismo balde: la IP del proxy.

**Los secretos se generan en el servidor.** No hay ninguno en el repositorio.
`api.env.example` es solo la plantilla con los campos vacíos.

**El `.env` de desarrollo nunca llega aquí.** Está en el `.gitignore` del repo,
y el de tu máquina apunta a un túnel SSH hacia otro servidor.

## Si algo sale mal

```bash
# ¿qué está corriendo? (desde este repo, en el servidor)
bash scripts/server.sh --no-pull --api

# logs de la API
docker logs -f --tail 100 marketplace_api

# ¿nginx se queja?
ssh root@2.25.75.147 'nginx -t && tail -50 /var/log/nginx/marketplace.error.log'

# base de datos por el túnel
ssh -L 5442:127.0.0.1:5442 deploy@2.25.75.147
```
