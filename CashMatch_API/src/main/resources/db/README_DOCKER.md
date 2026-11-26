# PostgreSQL local con Docker

Desde `src/main/resources`:

```
copiar .env.example a .env   (primera vez; edita DB_PASSWORD)
docker compose up -d         # el primer arranque carga db/base_datos_proyecto.sql
docker compose ps            # espera "healthy"
```

## DBeaver
Nueva conexion > PostgreSQL:
- Host: `localhost`  Puerto: `DB_PORT` del `.env` (por defecto `5433`)
- Base de datos: `cashmatch_erp`
- Usuario / contrasena: `DB_USER` / `DB_PASSWORD` del `.env`

DER: clic derecho en la base `cashmatch_erp` (o en el esquema `public`) > *View Diagram* / *Generate ER Diagram*.

## Resetear
`docker compose down -v` y luego `docker compose up -d` borra el volumen y recarga el SQL.
(El SQL solo se ejecuta cuando el volumen esta vacio; `down` sin `-v` conserva los datos.)

Notas: el puerto solo escucha en 127.0.0.1. El rol `cashmatch_app` es NOLOGIN; usa el usuario admin.
