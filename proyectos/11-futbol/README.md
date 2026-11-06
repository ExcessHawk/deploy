# 11-futbol

Fútbol Analytics en `futbol.alfredomejia.com.mx`. Un dashboard de Streamlit más
su Postgres. No tiene demostración ni cuentas: lo que enseña son resultados de
partidos, no datos de personas.

## En qué se diferencia de los demás

| | |
|---|---|
| No hay frontend | `WEB_REPO` vacío. Todo es Streamlit, no hay nada estático que publicar |
| No es de bun | `MIGRATE_CMD="python scripts/init_db.py"` |
| Habla por WebSocket | nginx necesita `Upgrade`; sin eso la página carga y se queda congelada |
| Trae datos | el esquema vacío no sirve de nada: hay que restaurar un volcado |

## Los datos

El esquema se crea solo, pero el dashboard sin datos es una pantalla con ceros.
Son ~42,600 partidos, 142,700 predicciones y las tablas derivadas. Volver a
ingerirlos en el servidor tomaría horas y gastaría cuota de API-Football, así
que se ingiere en la máquina de desarrollo una vez y se manda el volcado.

**Lo que no va**: la tabla `events` (eventos de StatsBomb, 833 MB). Solo la usa
`build_metrics.py` para construir las tablas derivadas; el dashboard nunca la
consulta. Se excluyen sus filas, no la tabla, para que el esquema siga completo.
A cambio, `build_metrics.py` no se puede volver a correr en el servidor — se
corre en desarrollo y se manda el resultado, que es lo que ya pasa.

Con eso el volcado baja de 1.1 GB a **23 MB**.

### Generarlo (en desarrollo, con el contenedor local arriba)

```bash
cd python/futbol-analytics
docker exec futbol-db pg_dump -U futbol -d futbol \
  -Fc --compress=9 --exclude-table-data=events -f /tmp/futbol.dump
docker cp futbol-db:/tmp/futbol.dump data/processed/futbol.dump
```

En Git Bash sobre Windows, antepón `MSYS_NO_PATHCONV=1` a los dos comandos: si
no, convierte `/tmp/futbol.dump` en una ruta de Windows y `pg_dump` falla
diciendo que el directorio no existe.

### Restaurarlo (en el servidor, con la pila ya levantada)

```bash
scp python/futbol-analytics/data/processed/futbol.dump deploy@SERVIDOR:/tmp/

ssh deploy@SERVIDOR
docker cp /tmp/futbol.dump futbol_postgres:/tmp/futbol.dump
docker exec -i futbol_postgres pg_restore \
  -U futbol -d futbol --no-owner --clean --if-exists /tmp/futbol.dump
rm /tmp/futbol.dump
docker exec futbol_postgres rm /tmp/futbol.dump
```

`--clean --if-exists` lo hace repetible: restaurar de nuevo reemplaza, no
duplica. `--no-owner` porque el dueño de las tablas en desarrollo no tiene por
qué existir aquí.

Después, comprobar que llegó:

```bash
docker exec futbol_postgres psql -U futbol -d futbol \
  -c "select count(*) from fd_matches" -c "select count(*) from predictions"
```

## Desplegar

```bash
cd ~/portafolio/deploy && git pull
bash scripts/server.sh 11-futbol              # construye imagen, levanta, crea esquema
sudo -E bash scripts/server.sh 11-futbol --tls
sudo cp proyectos/11-futbol/cron/futbol-update /etc/cron.d/futbol-update
sudo chmod 644 /etc/cron.d/futbol-update
```

El DNS tiene que existir **antes** de `--tls`: certbot valida por HTTP y si el
nombre no apunta aquí, falla y deja el sitio en el 80.

## La clave de API-Football

`bootstrap.sh` genera `api.env` con `APIFOOTBALL_KEY=` vacío. Sin ella el
dashboard funciona con todo lo que trae el volcado; lo que deja de llegar son
los partidos nuevos de la temporada en curso. Para ponerla, en el servidor:

```bash
sudo -u deploy nano ~/portafolio/futbol-analytics/api.env
docker restart futbol_app
```

Nunca en este repositorio. El plan Pro de esa cuenta vence el **6 de diciembre
de 2026**; cuando caduque, `update.py` lo registra y sigue con el resto.

## Si algo sale mal

| Síntoma | Causa | Qué hacer |
|---|---|---|
| La página carga y se queda en "Please wait..." | nginx no está pasando el WebSocket | Revisar que el `map $http_upgrade` y el `location /_stcore/stream` estén en la conf cargada |
| `server.sh` se rinde esperando la API | Streamlit tarda más que el arranque de los otros | Ya hay 60 s; si no basta, `docker logs futbol_app` |
| Todo en cero | El volcado no se restauró | Contar filas en `fd_matches` |
| "tesseract is not installed" al subir un boleto | La imagen se construyó sin los paquetes de apt | Reconstruir sin caché |
| El cron no escribe nada | `futbol_app` no estaba arriba a las 06:00 | `cat /var/log/futbol-update.log` |
