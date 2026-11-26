-- =============================================================================
-- CashMatch ERP - Fase 1 (persistencia)
-- Motor de conciliacion bancaria y dispersion de pagos a proveedores
-- Motor: PostgreSQL 14+   |   Convencion: snake_case   |   Esquema: public
-- Un solo archivo: DDL + DML. Reproducible (estrategia: DROP ... IF EXISTS ... CASCADE
-- al inicio y CREATE normal despues).
--
-- *** DESTRUCTIVO: elimina y recrea todoo; solo para desarrollo/CI. ***
-- Re-ejecutarlo BORRA TODOS LOS DATOS de las 13 tablas y los recarga con los datos de
-- prueba. NUNCA ejecutarlo contra una base con datos reales. Como salvaguarda, el script
-- aborta si current_database() no es 'cashmatch_erp' (la guarda corre dentro de la
-- transaccion, antes de cualquier DROP; si falla, el resto del script no se aplica).
-- =============================================================================
--
-- PASO 0 (manual, FUERA de este script): crear la base y conectarse a ella.
-- CREATE DATABASE no puede ejecutarse dentro de una transaccion, por eso va comentado:
--
--   psql -v ON_ERROR_STOP=1 -U postgres -c "CREATE DATABASE cashmatch_erp ENCODING 'UTF8'"
--   psql -v ON_ERROR_STOP=1 -U postgres -d cashmatch_erp -f base_datos_proyecto.sql
--
-- Nota: -v ON_ERROR_STOP=1 es necesario; sin el, psql continua tras un error (p. ej. dentro
-- de la transaccion ya abortada) y termina con exit code 0, ocultando el fallo.
--
-- (o, desde psql: primero \set ON_ERROR_STOP 1, luego CREATE DATABASE cashmatch_erp; \c cashmatch_erp y \i base_datos_proyecto.sql)
--
-- CONVENCION DE AUDITORIA (todas las tablas, incluidas las puente):
--   estatus              SMALLINT  1 = activo, 2 = inactivo, 3 = borrado logico
--   fecha_registro       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
--   fecha_actualizacion  TIMESTAMP DEFAULT CURRENT_TIMESTAMP (se refresca con trigger en cada UPDATE)
-- `estatus` es SOLO el ciclo de vida del registro. Los estados de negocio viven en
-- columnas estado_* separadas (estado_pago, estado_lote, estado_conciliacion, ...).
-- Prohibido DELETE fisico en operacion normal: el rol cashmatch_app no tiene permiso DELETE.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. GUARDA DEL SCRIPT DESTRUCTIVO (antes de cualquier DROP ... CASCADE)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'cashmatch_erp' THEN
        RAISE EXCEPTION 'Script destructivo abortado: la base actual es "%" y solo se permite "cashmatch_erp".',
            current_database();
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 1. LIMPIEZA (orden inverso de dependencias)
-- -----------------------------------------------------------------------------
DROP VIEW  IF EXISTS v_proveedores_publico CASCADE;

DROP TABLE IF EXISTS lote_pago_facturas       CASCADE;
DROP TABLE IF EXISTS lotes_pago               CASCADE;
DROP TABLE IF EXISTS conciliacion_facturas    CASCADE;
DROP TABLE IF EXISTS conciliacion_movimientos CASCADE;
DROP TABLE IF EXISTS conciliaciones           CASCADE;
DROP TABLE IF EXISTS facturas                 CASCADE;
DROP TABLE IF EXISTS proveedores              CASCADE;
DROP TABLE IF EXISTS movimientos_bancarios    CASCADE;
DROP TABLE IF EXISTS extractos_bancarios      CASCADE;
DROP TABLE IF EXISTS cuentas_bancarias        CASCADE;
DROP TABLE IF EXISTS bancos                   CASCADE;
DROP TABLE IF EXISTS usuarios                 CASCADE;
DROP TABLE IF EXISTS roles                    CASCADE;

DROP FUNCTION IF EXISTS fn_actualizar_fecha_actualizacion()  CASCADE;
DROP FUNCTION IF EXISTS fn_validar_fecha_emision_factura()   CASCADE;
DROP FUNCTION IF EXISTS fn_proteger_fecha_registro()         CASCADE;
DROP FUNCTION IF EXISTS fn_proteger_factura_no_pendiente()   CASCADE;
DROP FUNCTION IF EXISTS fn_proteger_lote_pago()              CASCADE;
DROP FUNCTION IF EXISTS fn_proteger_lote_pago_factura()      CASCADE;
DROP FUNCTION IF EXISTS fn_proteger_movimiento_conciliado()  CASCADE;
DROP FUNCTION IF EXISTS fn_clabe_valida(text)                CASCADE;

-- -----------------------------------------------------------------------------
-- 2. FUNCIONES DE TRIGGER
-- -----------------------------------------------------------------------------
-- En PostgreSQL el DEFAULT no se aplica en UPDATE: esta funcion unica refresca
-- fecha_actualizacion; cada tabla tiene su propio trigger que la invoca.
CREATE FUNCTION fn_actualizar_fecha_actualizacion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.fecha_actualizacion := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- CHECK (fecha_emision <= CURRENT_DATE) no es posible (CURRENT_DATE no es inmutable),
-- por eso la regla se implementa con trigger.
CREATE FUNCTION fn_validar_fecha_emision_factura()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.fecha_emision > CURRENT_DATE THEN
        RAISE EXCEPTION 'La fecha de emision (%) no puede ser futura', NEW.fecha_emision
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Inmutabilidad de fecha_registro: generica, se aplica a las 13 tablas.
CREATE FUNCTION fn_proteger_fecha_registro()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.fecha_registro IS DISTINCT FROM OLD.fecha_registro THEN
        RAISE EXCEPTION 'fecha_registro es inmutable (tabla %, id %)', TG_TABLE_NAME, OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Facturas: una vez que salen de PENDIENTE, sus datos economicos/de origen quedan congelados.
-- Siguen permitidos: cambios de estado_pago validos, estatus (borrado logico) y fechas.
CREATE FUNCTION fn_proteger_factura_no_pendiente()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado_pago <> 'PENDIENTE' AND (
           NEW.monto_total      IS DISTINCT FROM OLD.monto_total
        OR NEW.proveedor_id     IS DISTINCT FROM OLD.proveedor_id
        OR NEW.folio_referencia IS DISTINCT FROM OLD.folio_referencia
        OR NEW.creado_por       IS DISTINCT FROM OLD.creado_por) THEN
        RAISE EXCEPTION 'Factura % (estado_pago = %): monto_total, proveedor_id, folio_referencia y creado_por son inmutables fuera de PENDIENTE',
            OLD.id, OLD.estado_pago
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Lotes: monto/creador/codigo congelados fuera de PENDIENTE; AUTORIZADO y RECHAZADO son finales.
CREATE FUNCTION fn_proteger_lote_pago()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado_lote <> 'PENDIENTE' AND (
           NEW.monto_total IS DISTINCT FROM OLD.monto_total
        OR NEW.creado_por  IS DISTINCT FROM OLD.creado_por
        OR NEW.codigo      IS DISTINCT FROM OLD.codigo) THEN
        RAISE EXCEPTION 'Lote % (estado_lote = %): monto_total, creado_por y codigo son inmutables fuera de PENDIENTE',
            OLD.id, OLD.estado_lote
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF OLD.estado_lote IN ('AUTORIZADO', 'RECHAZADO') AND NEW.estado_lote <> OLD.estado_lote THEN
        RAISE EXCEPTION 'Lote %: el estado % es final y no puede cambiar a %',
            OLD.id, OLD.estado_lote, NEW.estado_lote
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    -- Una vez decidido (AUTORIZADO/RECHAZADO) tampoco se reescribe la decision. La transicion
    -- valida PENDIENTE -> AUTORIZADO/RECHAZADO no entra aqui (OLD.estado_lote = PENDIENTE).
    IF OLD.estado_lote IN ('AUTORIZADO', 'RECHAZADO') AND (
           NEW.autorizado_por     IS DISTINCT FROM OLD.autorizado_por
        OR NEW.fecha_autorizacion IS DISTINCT FROM OLD.fecha_autorizacion
        OR NEW.motivo_rechazo     IS DISTINCT FROM OLD.motivo_rechazo) THEN
        RAISE EXCEPTION 'Lote % (estado_lote = %): autorizado_por, fecha_autorizacion y motivo_rechazo son inmutables en un estado final',
            OLD.id, OLD.estado_lote
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Detalle de lote: si el lote padre ya fue decidido, lote_id, factura_id y monto_pagado quedan
-- congelados (estatus sigue permitido para el borrado logico).
CREATE FUNCTION fn_proteger_lote_pago_factura()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_lote VARCHAR;
BEGIN
    IF NEW.lote_id      IS DISTINCT FROM OLD.lote_id
    OR NEW.factura_id   IS DISTINCT FROM OLD.factura_id
    OR NEW.monto_pagado IS DISTINCT FROM OLD.monto_pagado THEN
        SELECT estado_lote INTO v_estado_lote FROM lotes_pago WHERE id = OLD.lote_id;
        IF v_estado_lote IN ('AUTORIZADO', 'RECHAZADO') THEN
            RAISE EXCEPTION 'Detalle de lote % (estado_lote = %): lote_id, factura_id y monto_pagado son inmutables',
                OLD.id, v_estado_lote
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- Movimientos: una vez CONCILIADO no se altera su importe, sentido ni fecha.
CREATE FUNCTION fn_proteger_movimiento_conciliado()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado_conciliacion = 'CONCILIADO' AND (
           NEW.monto            IS DISTINCT FROM OLD.monto
        OR NEW.tipo             IS DISTINCT FROM OLD.tipo
        OR NEW.fecha_movimiento IS DISTINCT FROM OLD.fecha_movimiento) THEN
        RAISE EXCEPTION 'Movimiento %: monto, tipo y fecha_movimiento son inmutables cuando estado_conciliacion = CONCILIADO',
            OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Digito verificador de la CLABE (18 digitos): pesos 3,7,1 repetidos sobre los 17 primeros
-- digitos; cada producto mod 10; se suman; digito = (10 - suma mod 10) mod 10.
CREATE FUNCTION fn_clabe_valida(p_clabe text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_suma integer := 0;
    v_pesos integer[] := ARRAY[3, 7, 1];
BEGIN
    IF p_clabe IS NULL OR p_clabe !~ '^[0-9]{18}$' THEN
        RETURN FALSE;
    END IF;
    FOR i IN 1..17 LOOP
        v_suma := v_suma + ((substr(p_clabe, i, 1)::integer * v_pesos[((i - 1) % 3) + 1]) % 10);
    END LOOP;
    RETURN ((10 - (v_suma % 10)) % 10) = substr(p_clabe, 18, 1)::integer;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. DDL (ordenado por dependencias de FK)
-- -----------------------------------------------------------------------------

-- 3.1 roles ------------------------------------------------------------------
CREATE TABLE roles (
    id                   INTEGER      GENERATED ALWAYS AS IDENTITY,
    nombre               VARCHAR(40)  NOT NULL,
    descripcion          VARCHAR(255),
    estatus              SMALLINT     NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_roles          PRIMARY KEY (id),
    CONSTRAINT uq_roles_nombre   UNIQUE (nombre),
    CONSTRAINT ck_roles_estatus  CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_roles_nombre   CHECK (nombre ~ '^[A-Z_]{3,40}$')
);

-- 3.2 usuarios (sin contrasenas: la autenticacion esta fuera de alcance en Fase 1) --
CREATE TABLE usuarios (
    id                   INTEGER      GENERATED ALWAYS AS IDENTITY,
    rol_id               INTEGER      NOT NULL,
    nombre_usuario       VARCHAR(50)  NOT NULL,
    nombre_completo      VARCHAR(120) NOT NULL,
    correo               VARCHAR(120) NOT NULL,
    estatus              SMALLINT     NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_usuarios                PRIMARY KEY (id),
    CONSTRAINT fk_usuarios_rol            FOREIGN KEY (rol_id) REFERENCES roles (id),
    CONSTRAINT uq_usuarios_nombre_usuario UNIQUE (nombre_usuario),
    CONSTRAINT uq_usuarios_correo         UNIQUE (correo),
    CONSTRAINT ck_usuarios_estatus        CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_usuarios_correo         CHECK (correo ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

-- 3.3 bancos -----------------------------------------------------------------
CREATE TABLE bancos (
    id                   INTEGER      GENERATED ALWAYS AS IDENTITY,
    nombre               VARCHAR(80)  NOT NULL,
    clave_banco          CHAR(3),
    estatus              SMALLINT     NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_bancos              PRIMARY KEY (id),
    CONSTRAINT uq_bancos_clave_banco  UNIQUE (clave_banco),   -- opcional: NULL permitido y repetible
    CONSTRAINT ck_bancos_estatus      CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_bancos_clave_banco  CHECK (clave_banco IS NULL OR clave_banco ~ '^[0-9]{3}$')
);
-- Unicidad del nombre solo entre registros no borrados logicamente (permite reutilizar el nombre).
CREATE UNIQUE INDEX uq_bancos_nombre_vigente ON bancos (nombre) WHERE estatus <> 3;

-- 3.4 cuentas_bancarias ------------------------------------------------------
CREATE TABLE cuentas_bancarias (
    id                      INTEGER      GENERATED ALWAYS AS IDENTITY,
    banco_id                INTEGER      NOT NULL,
    alias                   VARCHAR(60)  NOT NULL,
    numero_cuenta_ultimos4  CHAR(4)      NOT NULL,
    clabe                   CHAR(18)     NOT NULL,
    moneda                  CHAR(3)      NOT NULL DEFAULT 'MXN',
    estatus                 SMALLINT     NOT NULL DEFAULT 1,
    fecha_registro          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_cuentas_bancarias         PRIMARY KEY (id),
    CONSTRAINT fk_cuentas_bancarias_banco   FOREIGN KEY (banco_id) REFERENCES bancos (id),
    CONSTRAINT uq_cuentas_bancarias_clabe   UNIQUE (clabe),
    CONSTRAINT ck_cuentas_bancarias_estatus CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_cuentas_bancarias_clabe   CHECK (clabe ~ '^[0-9]{18}$' AND fn_clabe_valida(clabe)),
    CONSTRAINT ck_cuentas_bancarias_ult4    CHECK (numero_cuenta_ultimos4 ~ '^[0-9]{4}$'),
    CONSTRAINT ck_cuentas_bancarias_moneda  CHECK (moneda ~ '^[A-Z]{3}$')
);

-- 3.5 extractos_bancarios (el archivo NO se guarda en BD: solo su ruta) ---------
CREATE TABLE extractos_bancarios (
    id                   INTEGER       GENERATED ALWAYS AS IDENTITY,
    cuenta_bancaria_id   INTEGER       NOT NULL,
    cargado_por          INTEGER       NOT NULL,
    nombre_archivo       VARCHAR(150)  NOT NULL,
    ruta_archivo         VARCHAR(255)  NOT NULL,
    formato              VARCHAR(3)    NOT NULL,
    tamano_bytes         INTEGER       NOT NULL,
    estado_validacion    VARCHAR(10)   NOT NULL DEFAULT 'PENDIENTE',
    total_registros      INTEGER       NOT NULL DEFAULT 0,
    estatus              SMALLINT      NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_extractos_bancarios         PRIMARY KEY (id),
    CONSTRAINT fk_extractos_cuenta            FOREIGN KEY (cuenta_bancaria_id) REFERENCES cuentas_bancarias (id),
    CONSTRAINT fk_extractos_cargado_por       FOREIGN KEY (cargado_por) REFERENCES usuarios (id),
    CONSTRAINT uq_extractos_ruta_archivo      UNIQUE (ruta_archivo),
    CONSTRAINT ck_extractos_estatus           CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_extractos_formato           CHECK (formato IN ('CSV', 'TXT')),
    CONSTRAINT ck_extractos_tamano_bytes      CHECK (tamano_bytes > 0 AND tamano_bytes <= 10485760),  -- max 10 MiB (10485760 bytes)
    CONSTRAINT ck_extractos_estado_validacion CHECK (estado_validacion IN ('PENDIENTE', 'VALIDO', 'ERROR')),
    CONSTRAINT ck_extractos_total_registros   CHECK (total_registros >= 0),
    -- Ruta logica con '/' inicial bajo /uploads/extractos/ (no es ruta absoluta del sistema de
    -- archivos), sin '..' ni subdirectorios adicionales: evita path traversal.
    CONSTRAINT ck_extractos_ruta_archivo      CHECK (ruta_archivo ~ '^/uploads/extractos/[A-Za-z0-9._-]+\.(csv|txt)$'
                                                     AND ruta_archivo !~ '\.\.')
);

-- 3.6 movimientos_bancarios --------------------------------------------------
-- Modelado cargo/abono: columna `tipo` + monto SIEMPRE positivo (monto > 0).
-- CARGO = salida de dinero (pago a proveedor); ABONO = entrada.
CREATE TABLE movimientos_bancarios (
    id                    INTEGER        GENERATED ALWAYS AS IDENTITY,
    extracto_id           INTEGER        NOT NULL,
    fecha_movimiento      DATE           NOT NULL,
    descripcion           VARCHAR(255)   NOT NULL,
    referencia            VARCHAR(60),
    tipo                  VARCHAR(5)     NOT NULL,
    monto                 NUMERIC(14,2)  NOT NULL,
    estado_conciliacion   VARCHAR(10)    NOT NULL DEFAULT 'PENDIENTE',
    estatus               SMALLINT       NOT NULL DEFAULT 1,
    fecha_registro        TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion   TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_movimientos_bancarios       PRIMARY KEY (id),
    CONSTRAINT fk_movimientos_extracto        FOREIGN KEY (extracto_id) REFERENCES extractos_bancarios (id),
    CONSTRAINT ck_movimientos_estatus         CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_movimientos_tipo            CHECK (tipo IN ('CARGO', 'ABONO')),
    CONSTRAINT ck_movimientos_monto           CHECK (monto > 0),
    CONSTRAINT ck_movimientos_estado_concil   CHECK (estado_conciliacion IN ('PENDIENTE', 'CONCILIADO'))
);

-- 3.7 proveedores ------------------------------------------------------------
-- La CLABE se guarda completa (se requiere para dispersar el pago). El enmascarado
-- (***4401) se hace en la capa API o con la vista v_proveedores_publico.
CREATE TABLE proveedores (
    id                   INTEGER       GENERATED ALWAYS AS IDENTITY,
    razon_social         VARCHAR(100)  NOT NULL,
    rfc                  VARCHAR(13)   NOT NULL,
    clabe                CHAR(18)      NOT NULL,
    estatus              SMALLINT      NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_proveedores               PRIMARY KEY (id),
    CONSTRAINT ck_proveedores_estatus       CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_proveedores_razon_social  CHECK (char_length(razon_social) BETWEEN 3 AND 100),
    CONSTRAINT ck_proveedores_rfc           CHECK (char_length(rfc) IN (12, 13) AND rfc ~ '^[A-Z&0-9]+$'),
    CONSTRAINT ck_proveedores_clabe         CHECK (clabe ~ '^[0-9]{18}$' AND fn_clabe_valida(clabe))
);
-- RFC unico solo entre proveedores no borrados logicamente (permite re-alta tras estatus = 3).
CREATE UNIQUE INDEX uq_proveedores_rfc_vigente ON proveedores (rfc) WHERE estatus <> 3;

-- 3.8 facturas ---------------------------------------------------------------
CREATE TABLE facturas (
    id                   INTEGER        GENERATED ALWAYS AS IDENTITY,
    proveedor_id         INTEGER        NOT NULL,
    creado_por           INTEGER        NOT NULL,
    folio_referencia     VARCHAR(20)    NOT NULL,
    fecha_emision        DATE           NOT NULL,
    fecha_vencimiento    DATE           NOT NULL,
    monto_total          NUMERIC(14,2)  NOT NULL,
    estado_pago          VARCHAR(10)    NOT NULL DEFAULT 'PENDIENTE',
    estatus              SMALLINT       NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_facturas                  PRIMARY KEY (id),
    CONSTRAINT fk_facturas_proveedor        FOREIGN KEY (proveedor_id) REFERENCES proveedores (id),
    CONSTRAINT fk_facturas_creado_por       FOREIGN KEY (creado_por) REFERENCES usuarios (id),
    CONSTRAINT ck_facturas_estatus          CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_facturas_folio            CHECK (folio_referencia ~ '^[A-Z0-9-]{3,20}$'),
    CONSTRAINT ck_facturas_monto_total      CHECK (monto_total > 0),
    CONSTRAINT ck_facturas_estado_pago      CHECK (estado_pago IN ('PENDIENTE', 'CONCILIADA', 'EN_LOTE', 'PAGADA', 'ANULADA')),
    CONSTRAINT ck_facturas_fechas           CHECK (fecha_vencimiento >= fecha_emision)
);
-- Folio unico por proveedor solo entre facturas no borradas logicamente.
CREATE UNIQUE INDEX uq_facturas_proveedor_folio_vigente
    ON facturas (proveedor_id, folio_referencia) WHERE estatus <> 3;

-- 3.9 conciliaciones ---------------------------------------------------------
-- tolerancia_aplicada: porcentaje (0-5 %) de diferencia aceptada entre factura(s) y movimiento.
-- diferencia: monto absoluto (movimientos - facturas) resultante.
CREATE TABLE conciliaciones (
    id                   INTEGER        GENERATED ALWAYS AS IDENTITY,
    tipo                 VARCHAR(10)    NOT NULL,
    tolerancia_aplicada  NUMERIC(5,2)   NOT NULL DEFAULT 0,
    diferencia           NUMERIC(14,2)  NOT NULL DEFAULT 0,
    origen               VARCHAR(10)    NOT NULL,
    conciliado_por       INTEGER        NOT NULL,
    fecha_conciliacion   TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    estatus              SMALLINT       NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_conciliaciones                PRIMARY KEY (id),
    CONSTRAINT fk_conciliaciones_conciliado_por FOREIGN KEY (conciliado_por) REFERENCES usuarios (id),
    CONSTRAINT ck_conciliaciones_estatus        CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_conciliaciones_tipo           CHECK (tipo IN ('UNO_A_UNO', 'UNO_A_N')),
    CONSTRAINT ck_conciliaciones_tolerancia     CHECK (tolerancia_aplicada BETWEEN 0 AND 5),
    CONSTRAINT ck_conciliaciones_origen         CHECK (origen IN ('AUTOMATICA', 'MANUAL'))
);

-- 3.10 conciliacion_movimientos (puente N:M) ----------------------------------
CREATE TABLE conciliacion_movimientos (
    id                   INTEGER    GENERATED ALWAYS AS IDENTITY,
    conciliacion_id      INTEGER    NOT NULL,
    movimiento_id        INTEGER    NOT NULL,
    estatus              SMALLINT   NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_conciliacion_movimientos        PRIMARY KEY (id),
    CONSTRAINT fk_conc_mov_conciliacion           FOREIGN KEY (conciliacion_id) REFERENCES conciliaciones (id),
    CONSTRAINT fk_conc_mov_movimiento             FOREIGN KEY (movimiento_id)   REFERENCES movimientos_bancarios (id),
    CONSTRAINT ck_conc_mov_estatus                CHECK (estatus IN (1, 2, 3))
);
-- Un movimiento solo puede pertenecer a UNA conciliacion activa (los borrados logicos no bloquean).
CREATE UNIQUE INDEX uq_conc_mov_movimiento_activo
    ON conciliacion_movimientos (movimiento_id) WHERE estatus = 1;
-- Evita duplicar el mismo par dentro de una conciliacion.
CREATE UNIQUE INDEX uq_conc_mov_par_activo
    ON conciliacion_movimientos (conciliacion_id, movimiento_id) WHERE estatus = 1;

-- 3.11 conciliacion_facturas (puente N:M) -------------------------------------
CREATE TABLE conciliacion_facturas (
    id                   INTEGER    GENERATED ALWAYS AS IDENTITY,
    conciliacion_id      INTEGER    NOT NULL,
    factura_id           INTEGER    NOT NULL,
    estatus              SMALLINT   NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_conciliacion_facturas           PRIMARY KEY (id),
    CONSTRAINT fk_conc_fac_conciliacion           FOREIGN KEY (conciliacion_id) REFERENCES conciliaciones (id),
    CONSTRAINT fk_conc_fac_factura                FOREIGN KEY (factura_id)      REFERENCES facturas (id),
    CONSTRAINT ck_conc_fac_estatus                CHECK (estatus IN (1, 2, 3))
);
CREATE UNIQUE INDEX uq_conc_fac_factura_activa
    ON conciliacion_facturas (factura_id) WHERE estatus = 1;
CREATE UNIQUE INDEX uq_conc_fac_par_activo
    ON conciliacion_facturas (conciliacion_id, factura_id) WHERE estatus = 1;

-- 3.12 lotes_pago ------------------------------------------------------------
-- Segregacion de funciones: quien autoriza (autorizado_por) debe ser distinto de quien crea.
CREATE TABLE lotes_pago (
    id                   INTEGER        GENERATED ALWAYS AS IDENTITY,
    codigo               VARCHAR(20)    NOT NULL,
    creado_por           INTEGER        NOT NULL,
    autorizado_por       INTEGER,
    estado_lote          VARCHAR(10)    NOT NULL DEFAULT 'PENDIENTE',
    monto_total          NUMERIC(14,2)  NOT NULL,
    motivo_rechazo       TEXT,
    fecha_autorizacion   TIMESTAMP,
    estatus              SMALLINT       NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_lotes_pago                 PRIMARY KEY (id),
    CONSTRAINT fk_lotes_pago_creado_por      FOREIGN KEY (creado_por)     REFERENCES usuarios (id),
    CONSTRAINT fk_lotes_pago_autorizado_por  FOREIGN KEY (autorizado_por) REFERENCES usuarios (id),
    CONSTRAINT ck_lotes_pago_estatus         CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_lotes_pago_codigo          CHECK (codigo ~ '^[A-Z0-9-]{3,20}$'),
    CONSTRAINT ck_lotes_pago_estado_lote     CHECK (estado_lote IN ('PENDIENTE', 'AUTORIZADO', 'RECHAZADO')),
    CONSTRAINT ck_lotes_pago_monto_total     CHECK (monto_total > 0),
    CONSTRAINT ck_lotes_pago_segregacion     CHECK (autorizado_por IS NULL OR autorizado_por <> creado_por),
    CONSTRAINT ck_lotes_pago_motivo_rechazo  CHECK (estado_lote <> 'RECHAZADO'
                                                    OR (motivo_rechazo IS NOT NULL AND char_length(regexp_replace(motivo_rechazo, '^\s+|\s+$', '', 'g')) >= 15)),
    CONSTRAINT ck_lotes_pago_autorizacion    CHECK (estado_lote <> 'AUTORIZADO'
                                                    OR (autorizado_por IS NOT NULL AND fecha_autorizacion IS NOT NULL))
);
-- Codigo de lote unico solo entre lotes no borrados logicamente.
CREATE UNIQUE INDEX uq_lotes_pago_codigo_vigente ON lotes_pago (codigo) WHERE estatus <> 3;

-- 3.13 lote_pago_facturas (puente N:M lotes <-> facturas) ---------------------
CREATE TABLE lote_pago_facturas (
    id                   INTEGER        GENERATED ALWAYS AS IDENTITY,
    lote_id              INTEGER        NOT NULL,
    factura_id           INTEGER        NOT NULL,
    monto_pagado         NUMERIC(14,2)  NOT NULL,
    estatus              SMALLINT       NOT NULL DEFAULT 1,
    fecha_registro       TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion  TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_lote_pago_facturas         PRIMARY KEY (id),
    CONSTRAINT fk_lote_pago_fac_lote         FOREIGN KEY (lote_id)    REFERENCES lotes_pago (id),
    CONSTRAINT fk_lote_pago_fac_factura      FOREIGN KEY (factura_id) REFERENCES facturas (id),
    CONSTRAINT ck_lote_pago_fac_estatus      CHECK (estatus IN (1, 2, 3)),
    CONSTRAINT ck_lote_pago_fac_monto        CHECK (monto_pagado > 0)
);
CREATE UNIQUE INDEX uq_lote_pago_fac_par_activo
    ON lote_pago_facturas (lote_id, factura_id) WHERE estatus = 1;

-- -----------------------------------------------------------------------------
-- 4. INDICES (todas las FK + columnas de consulta frecuente)
--    Los parciales WHERE estatus = 1 sirven a las consultas operativas (solo activos).
-- -----------------------------------------------------------------------------
CREATE INDEX idx_usuarios_rol_id                 ON usuarios (rol_id);
CREATE INDEX idx_cuentas_bancarias_banco_id      ON cuentas_bancarias (banco_id);
CREATE INDEX idx_extractos_cuenta_bancaria_id    ON extractos_bancarios (cuenta_bancaria_id);
CREATE INDEX idx_extractos_cargado_por           ON extractos_bancarios (cargado_por);
CREATE INDEX idx_extractos_estado_validacion     ON extractos_bancarios (estado_validacion) WHERE estatus = 1;
CREATE INDEX idx_movimientos_extracto_id         ON movimientos_bancarios (extracto_id);
CREATE INDEX idx_movimientos_fecha_movimiento    ON movimientos_bancarios (fecha_movimiento) WHERE estatus = 1;
CREATE INDEX idx_movimientos_estado_conciliacion ON movimientos_bancarios (estado_conciliacion) WHERE estatus = 1;
CREATE INDEX idx_facturas_proveedor_id           ON facturas (proveedor_id);
CREATE INDEX idx_facturas_creado_por             ON facturas (creado_por);
CREATE INDEX idx_facturas_estado_pago            ON facturas (estado_pago) WHERE estatus = 1;
CREATE INDEX idx_facturas_fecha_vencimiento      ON facturas (fecha_vencimiento) WHERE estatus = 1;
CREATE INDEX idx_conciliaciones_conciliado_por   ON conciliaciones (conciliado_por);
CREATE INDEX idx_conc_mov_conciliacion_id        ON conciliacion_movimientos (conciliacion_id);
CREATE INDEX idx_conc_mov_movimiento_id          ON conciliacion_movimientos (movimiento_id);
CREATE INDEX idx_conc_fac_conciliacion_id        ON conciliacion_facturas (conciliacion_id);
CREATE INDEX idx_conc_fac_factura_id             ON conciliacion_facturas (factura_id);
CREATE INDEX idx_lotes_pago_creado_por           ON lotes_pago (creado_por);
CREATE INDEX idx_lotes_pago_autorizado_por       ON lotes_pago (autorizado_por);
CREATE INDEX idx_lotes_pago_estado_lote          ON lotes_pago (estado_lote) WHERE estatus = 1;
CREATE INDEX idx_lote_pago_fac_lote_id           ON lote_pago_facturas (lote_id);
CREATE INDEX idx_lote_pago_fac_factura_id        ON lote_pago_facturas (factura_id);

-- -----------------------------------------------------------------------------
-- 5. TRIGGERS
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_roles_fecha_actualizacion                    BEFORE UPDATE ON roles                    FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_usuarios_fecha_actualizacion                 BEFORE UPDATE ON usuarios                 FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_bancos_fecha_actualizacion                   BEFORE UPDATE ON bancos                   FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_cuentas_bancarias_fecha_actualizacion        BEFORE UPDATE ON cuentas_bancarias        FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_extractos_bancarios_fecha_actualizacion      BEFORE UPDATE ON extractos_bancarios      FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_movimientos_bancarios_fecha_actualizacion    BEFORE UPDATE ON movimientos_bancarios    FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_proveedores_fecha_actualizacion              BEFORE UPDATE ON proveedores              FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_facturas_fecha_actualizacion                 BEFORE UPDATE ON facturas                 FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_conciliaciones_fecha_actualizacion           BEFORE UPDATE ON conciliaciones           FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_conciliacion_movimientos_fecha_actualizacion BEFORE UPDATE ON conciliacion_movimientos FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_conciliacion_facturas_fecha_actualizacion    BEFORE UPDATE ON conciliacion_facturas    FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_lotes_pago_fecha_actualizacion               BEFORE UPDATE ON lotes_pago               FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();
CREATE TRIGGER trg_lote_pago_facturas_fecha_actualizacion       BEFORE UPDATE ON lote_pago_facturas       FOR EACH ROW EXECUTE FUNCTION fn_actualizar_fecha_actualizacion();

-- Regla "fecha_emision no futura" (no expresable como CHECK).
CREATE TRIGGER trg_facturas_validar_fecha_emision
    BEFORE INSERT OR UPDATE ON facturas
    FOR EACH ROW EXECUTE FUNCTION fn_validar_fecha_emision_factura();

-- Inmutabilidad de fecha_registro (un trigger por tabla, misma funcion generica).
CREATE TRIGGER trg_roles_proteger_fecha_registro                    BEFORE UPDATE ON roles                    FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_usuarios_proteger_fecha_registro                 BEFORE UPDATE ON usuarios                 FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_bancos_proteger_fecha_registro                   BEFORE UPDATE ON bancos                   FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_cuentas_bancarias_proteger_fecha_registro        BEFORE UPDATE ON cuentas_bancarias        FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_extractos_bancarios_proteger_fecha_registro      BEFORE UPDATE ON extractos_bancarios      FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_movimientos_bancarios_proteger_fecha_registro    BEFORE UPDATE ON movimientos_bancarios    FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_proveedores_proteger_fecha_registro              BEFORE UPDATE ON proveedores              FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_facturas_proteger_fecha_registro                 BEFORE UPDATE ON facturas                 FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_conciliaciones_proteger_fecha_registro           BEFORE UPDATE ON conciliaciones           FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_conciliacion_movimientos_proteger_fecha_registro BEFORE UPDATE ON conciliacion_movimientos FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_conciliacion_facturas_proteger_fecha_registro    BEFORE UPDATE ON conciliacion_facturas    FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_lotes_pago_proteger_fecha_registro               BEFORE UPDATE ON lotes_pago               FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();
CREATE TRIGGER trg_lote_pago_facturas_proteger_fecha_registro       BEFORE UPDATE ON lote_pago_facturas       FOR EACH ROW EXECUTE FUNCTION fn_proteger_fecha_registro();

-- Inmutabilidad de datos economicos una vez que el registro avanza en su flujo de negocio.
CREATE TRIGGER trg_facturas_proteger_no_pendiente
    BEFORE UPDATE ON facturas
    FOR EACH ROW EXECUTE FUNCTION fn_proteger_factura_no_pendiente();
CREATE TRIGGER trg_lotes_pago_proteger_estado
    BEFORE UPDATE ON lotes_pago
    FOR EACH ROW EXECUTE FUNCTION fn_proteger_lote_pago();
CREATE TRIGGER trg_lote_pago_facturas_proteger_lote_decidido
    BEFORE UPDATE ON lote_pago_facturas
    FOR EACH ROW EXECUTE FUNCTION fn_proteger_lote_pago_factura();
CREATE TRIGGER trg_movimientos_bancarios_proteger_conciliado
    BEFORE UPDATE ON movimientos_bancarios
    FOR EACH ROW EXECUTE FUNCTION fn_proteger_movimiento_conciliado();

-- -----------------------------------------------------------------------------
-- 6. VISTA PUBLICA (CLABE enmascarada)
--    La BD guarda la CLABE completa; el enmascarado tambien debe aplicarse en la API.
-- -----------------------------------------------------------------------------
CREATE VIEW v_proveedores_publico WITH (security_barrier = true) AS
SELECT id,
       razon_social,
       rfc,
       '***' || right(clabe, 4) AS clabe_enmascarada,
       estatus,
       fecha_registro,
       fecha_actualizacion
FROM proveedores
WHERE estatus <> 3;

-- -----------------------------------------------------------------------------
-- 7. COMENTARIOS (tablas y columna estatus)
-- -----------------------------------------------------------------------------
COMMENT ON TABLE roles                    IS 'Catalogo de roles funcionales (segregacion de funciones).';
COMMENT ON TABLE usuarios                 IS 'Usuarios del sistema para trazabilidad; sin credenciales (autenticacion fuera de alcance Fase 1).';
COMMENT ON TABLE bancos                   IS 'Catalogo de instituciones bancarias.';
COMMENT ON TABLE cuentas_bancarias        IS 'Cuentas bancarias de la empresa cuyos extractos se concilian.';
COMMENT ON TABLE extractos_bancarios      IS 'Archivos de extracto cargados (CSV/TXT); solo se almacena la ruta, nunca el contenido binario.';
COMMENT ON TABLE movimientos_bancarios    IS 'Movimientos (cargos/abonos) contenidos en un extracto bancario.';
COMMENT ON TABLE proveedores              IS 'Catalogo de proveedores con RFC y CLABE de dispersion.';
COMMENT ON TABLE facturas                 IS 'Facturas por pagar a proveedores y su estado de pago.';
COMMENT ON TABLE conciliaciones           IS 'Cabecera de una conciliacion bancaria (1 a 1 o 1 a N, automatica o manual).';
COMMENT ON TABLE conciliacion_movimientos IS 'Puente conciliaciones - movimientos bancarios.';
COMMENT ON TABLE conciliacion_facturas    IS 'Puente conciliaciones - facturas.';
COMMENT ON TABLE lotes_pago               IS 'Lotes de dispersion de pagos con flujo de autorizacion/rechazo.';
COMMENT ON TABLE lote_pago_facturas       IS 'Puente lotes de pago - facturas con el monto pagado por factura.';

COMMENT ON VIEW v_proveedores_publico IS 'Proveedores con CLABE enmascarada (***XXXX) para consumo sin exponer el dato completo.';

COMMENT ON COLUMN roles.estatus                    IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN usuarios.estatus                 IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN bancos.estatus                   IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN cuentas_bancarias.estatus        IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN extractos_bancarios.estatus      IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN movimientos_bancarios.estatus    IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN proveedores.estatus              IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN facturas.estatus                 IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN conciliaciones.estatus           IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN conciliacion_movimientos.estatus IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN conciliacion_facturas.estatus    IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN lotes_pago.estatus               IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';
COMMENT ON COLUMN lote_pago_facturas.estatus       IS 'Ciclo de vida del registro: 1 = activo, 2 = inactivo, 3 = borrado logico. No es un estado de negocio.';

COMMENT ON COLUMN proveedores.clabe                IS 'CLABE completa (necesaria para dispersar). El enmascarado (***4401) se aplica en la capa API / vista v_proveedores_publico.';
COMMENT ON COLUMN extractos_bancarios.ruta_archivo IS 'Ruta del archivo en el servidor (ej. /uploads/extractos/xxx.csv). Prohibido guardar BLOB/BYTEA/Base64.';
COMMENT ON COLUMN movimientos_bancarios.monto      IS 'Siempre positivo; el sentido lo da la columna tipo (CARGO/ABONO).';
COMMENT ON COLUMN conciliaciones.tolerancia_aplicada IS 'Porcentaje de tolerancia aplicado (0 a 5).';
COMMENT ON COLUMN lotes_pago.autorizado_por        IS 'Debe ser distinto de creado_por (segregacion de funciones).';

-- -----------------------------------------------------------------------------
-- 8. ROL DE APLICACION (privilegio minimo)
--    Sin DELETE y sin DDL: esto es lo que FUERZA el borrado logico (estatus = 3)
--    a nivel de base de datos. NOLOGIN: para habilitar conexion, el DBA debe ejecutar
--    aparte, con un secreto gestionado fuera del repositorio, por ejemplo:
--      ALTER ROLE cashmatch_app LOGIN PASSWORD '<<PLACEHOLDER_CAMBIAR_Y_NO_VERSIONAR>>';
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cashmatch_app') THEN
        CREATE ROLE cashmatch_app NOLOGIN;
    END IF;
END
$$;

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM cashmatch_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM cashmatch_app;
-- En PostgreSQL <= 14 el esquema public concede CREATE a PUBLIC por defecto: se revoca
-- (solo en esta base) para que el rol de aplicacion no pueda ejecutar DDL.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM cashmatch_app;
GRANT USAGE ON SCHEMA public TO cashmatch_app;
-- Solo las 13 tablas base (lista explicita): "ON ALL TABLES" tambien alcanzaria la vista.
GRANT SELECT, INSERT, UPDATE ON
    roles, usuarios, bancos, cuentas_bancarias, extractos_bancarios, movimientos_bancarios,
    proveedores, facturas, conciliaciones, conciliacion_movimientos, conciliacion_facturas,
    lotes_pago, lote_pago_facturas
    TO cashmatch_app;
-- La vista es de solo lectura para la aplicacion.
GRANT SELECT ON v_proveedores_publico TO cashmatch_app;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON v_proveedores_publico FROM cashmatch_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cashmatch_app;
-- (nunca GRANT DELETE / TRUNCATE / CREATE al rol de aplicacion)

-- Objetos futuros creados por el propietario de este script: sin DELETE. Por defecto solo
-- SELECT en tablas/vistas (una vista nueva nunca nace con INSERT/UPDATE); las tablas nuevas
-- que la app deba escribir requieren GRANT INSERT, UPDATE explicito (fallo seguro).
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cashmatch_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO cashmatch_app;

-- -----------------------------------------------------------------------------
-- 9. DML - DATOS DE PRUEBA FICTICIOS
--    estatus, fecha_registro y fecha_actualizacion toman su DEFAULT (no se insertan),
--    salvo los casos que demuestran registro inactivo / borrado logico.
--    Los ids se resuelven por claves unicas (no se asumen valores de identidad).
-- -----------------------------------------------------------------------------

INSERT INTO roles (nombre, descripcion) VALUES
    ('ANALISTA_CXP',      'Captura facturas, concilia y arma lotes de pago'),
    ('TESORERO_AUDITOR',  'Revisa conciliaciones y autoriza o rechaza lotes'),
    ('DIRECTOR_FINANZAS', 'Supervisa y autoriza lotes de alto monto');

INSERT INTO usuarios (rol_id, nombre_usuario, nombre_completo, correo) VALUES
    ((SELECT id FROM roles WHERE nombre = 'ANALISTA_CXP'),      'analista01',  'Ana Lopez Ejemplo',        'analista01@cashmatch.example'),
    ((SELECT id FROM roles WHERE nombre = 'TESORERO_AUDITOR'),  'tesorero01',  'Tomas Reyes Ejemplo',      'tesorero01@cashmatch.example'),
    ((SELECT id FROM roles WHERE nombre = 'DIRECTOR_FINANZAS'), 'director01',  'Diana Torres Ejemplo',     'director01@cashmatch.example');

INSERT INTO bancos (nombre, clave_banco) VALUES
    ('BBVA Mexico',  '012'),
    ('Banorte',      '072'),
    ('Santander',    '014');

INSERT INTO cuentas_bancarias (banco_id, alias, numero_cuenta_ultimos4, clabe) VALUES
    ((SELECT id FROM bancos WHERE nombre = 'BBVA Mexico'), 'Operativa principal', '1234', '012180001234567899'),
    ((SELECT id FROM bancos WHERE nombre = 'Banorte'),     'Nomina y servicios',  '5678', '072180005678901235'),
    ((SELECT id FROM bancos WHERE nombre = 'Santander'),   'Cobranza',            '9012', '014180009012345673');

INSERT INTO extractos_bancarios
    (cuenta_bancaria_id, cargado_por, nombre_archivo, ruta_archivo, formato, tamano_bytes, estado_validacion, total_registros)
VALUES
    ((SELECT id FROM cuentas_bancarias WHERE clabe = '012180001234567899'),
     (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'extracto_bbva_2026_09.csv', '/uploads/extractos/extracto_bbva_2026_09.csv', 'CSV', 20480, 'VALIDO', 4),
    ((SELECT id FROM cuentas_bancarias WHERE clabe = '072180005678901235'),
     (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'extracto_banorte_2026_09.txt', '/uploads/extractos/extracto_banorte_2026_09.txt', 'TXT', 15360, 'VALIDO', 2),
    ((SELECT id FROM cuentas_bancarias WHERE clabe = '014180009012345673'),
     (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'extracto_santander_2026_10.csv', '/uploads/extractos/extracto_santander_2026_10.csv', 'CSV', 9216, 'PENDIENTE', 0);

INSERT INTO movimientos_bancarios
    (extracto_id, fecha_movimiento, descripcion, referencia, tipo, monto, estado_conciliacion)
VALUES
    ((SELECT id FROM extractos_bancarios WHERE nombre_archivo = 'extracto_bbva_2026_09.csv'),
     '2026-09-10', 'SPEI ENVIADO ABARROTES DEL NORTE', 'FAC-ABN-0001', 'CARGO', 11500.00, 'CONCILIADO'),
    ((SELECT id FROM extractos_bancarios WHERE nombre_archivo = 'extracto_bbva_2026_09.csv'),
     '2026-09-12', 'SPEI ENVIADO TECNOLOGIA FENIX',    'FAC-TFX-0010/0011', 'CARGO', 10000.00, 'CONCILIADO'),
    ((SELECT id FROM extractos_bancarios WHERE nombre_archivo = 'extracto_bbva_2026_09.csv'),
     '2026-09-15', 'DEPOSITO CLIENTE VARIOS',          'DEP-88231', 'ABONO', 25000.00, 'PENDIENTE'),
    ((SELECT id FROM extractos_bancarios WHERE nombre_archivo = 'extracto_bbva_2026_09.csv'),
     '2026-09-18', 'COMISION MANEJO DE CUENTA',        NULL,        'CARGO',   350.00, 'PENDIENTE'),
    ((SELECT id FROM extractos_bancarios WHERE nombre_archivo = 'extracto_banorte_2026_09.txt'),
     '2026-09-20', 'SPEI ENVIADO ABARROTES DEL NORTE', 'FAC-ABN-0002', 'CARGO',  2500.00, 'CONCILIADO'),
    ((SELECT id FROM extractos_bancarios WHERE nombre_archivo = 'extracto_banorte_2026_09.txt'),
     '2026-09-22', 'SPEI ENVIADO SERVICIOS LUNA',      'FAC-SLU-0100', 'CARGO', 8200.00, 'PENDIENTE');

INSERT INTO proveedores (razon_social, rfc, clabe) VALUES
    ('Abarrotes del Norte SA de CV',  'ADN150312AB1',  '012180004455667782'),
    ('Tecnologia Fenix SA de CV',     'TFE190820HB7',  '072180002233445566'),
    ('Servicios Luna SC',             'SLU101105QX9',  '014180007788990011');

-- Caso de demostracion: proveedor inactivo (estatus explicito = 2).
INSERT INTO proveedores (razon_social, rfc, clabe, estatus) VALUES
    ('Distribuidora Ocaso SA de CV',  'DOC080229KT4',  '012180009900112237', 2);

-- Facturas (estado_pago coherente con los flujos de abajo).
INSERT INTO facturas (proveedor_id, creado_por, folio_referencia, fecha_emision, fecha_vencimiento, monto_total, estado_pago)
VALUES
    ((SELECT id FROM proveedores WHERE rfc = 'ADN150312AB1'), (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'FAC-ABN-0001', '2026-08-20', '2026-09-19', 11500.00, 'CONCILIADA'),
    ((SELECT id FROM proveedores WHERE rfc = 'ADN150312AB1'), (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'FAC-ABN-0002', '2026-08-25', '2026-09-24',  2500.00, 'PAGADA'),
    ((SELECT id FROM proveedores WHERE rfc = 'TFE190820HB7'), (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'FAC-TFX-0010', '2026-08-28', '2026-09-27',  4000.00, 'CONCILIADA'),
    ((SELECT id FROM proveedores WHERE rfc = 'TFE190820HB7'), (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'FAC-TFX-0011', '2026-08-28', '2026-09-27',  6000.00, 'CONCILIADA'),
    ((SELECT id FROM proveedores WHERE rfc = 'SLU101105QX9'), (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'FAC-SLU-0100', '2026-09-01', '2026-10-01',  8200.00, 'EN_LOTE'),
    ((SELECT id FROM proveedores WHERE rfc = 'SLU101105QX9'), (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
     'FAC-SLU-0101', '2026-09-05', '2026-10-05',  3000.00, 'PENDIENTE');

-- Conciliaciones (se identifican por la pareja tipo+origen): (1) automatica 1 a 1;
-- (2) manual 1 movimiento a N facturas; (3) manual 1 a 1 (FAC-ABN-0002, ya PAGADA).
INSERT INTO conciliaciones (tipo, tolerancia_aplicada, diferencia, origen, conciliado_por) VALUES
    ('UNO_A_UNO', 0.00, 0.00, 'AUTOMATICA', (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01')),
    ('UNO_A_N',   0.00, 0.00, 'MANUAL',     (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01')),
    ('UNO_A_UNO', 0.00, 0.00, 'MANUAL',     (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'));

INSERT INTO conciliacion_movimientos (conciliacion_id, movimiento_id) VALUES
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_UNO' AND c.origen = 'AUTOMATICA'),
     (SELECT id FROM movimientos_bancarios WHERE referencia = 'FAC-ABN-0001')),
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_N' AND c.origen = 'MANUAL'),
     (SELECT id FROM movimientos_bancarios WHERE referencia = 'FAC-TFX-0010/0011')),
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_UNO' AND c.origen = 'MANUAL'),
     (SELECT id FROM movimientos_bancarios WHERE referencia = 'FAC-ABN-0002'));

INSERT INTO conciliacion_facturas (conciliacion_id, factura_id) VALUES
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_UNO' AND c.origen = 'AUTOMATICA'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'ADN150312AB1' AND f.folio_referencia = 'FAC-ABN-0001')),
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_UNO' AND c.origen = 'MANUAL'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'ADN150312AB1' AND f.folio_referencia = 'FAC-ABN-0002')),
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_N' AND c.origen = 'MANUAL'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'TFE190820HB7' AND f.folio_referencia = 'FAC-TFX-0010')),
    ((SELECT c.id FROM conciliaciones c WHERE c.tipo = 'UNO_A_N' AND c.origen = 'MANUAL'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'TFE190820HB7' AND f.folio_referencia = 'FAC-TFX-0011'));

-- Estado final coherente del flujo de demo (los registros se insertan YA en su estado final,
-- por lo que los triggers de inmutabilidad no intervienen):
--   FAC-ABN-0001 CONCILIADA <-> mov. CONCILIADO (conciliacion 1)
--   FAC-ABN-0002 PAGADA     <-> mov. CONCILIADO (conciliacion 3) + lote L-2026-09-A AUTORIZADO
--   FAC-TFX-0010/0011 CONCILIADAS <-> mov. CONCILIADO (conciliacion 2)
--   FAC-SLU-0100 EN_LOTE    <-> lote L-2026-09-B PENDIENTE (mov. aun PENDIENTE: no dispersado)
--   FAC-SLU-0101 PENDIENTE  <-> lote L-2026-09-C RECHAZADO (la factura regresa a PENDIENTE)

-- Lotes de pago: AUTORIZADO, PENDIENTE y RECHAZADO (creador siempre distinto del autorizador).
INSERT INTO lotes_pago (codigo, creado_por, autorizado_por, estado_lote, monto_total, motivo_rechazo, fecha_autorizacion) VALUES
    ('L-2026-09-A', (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
                    (SELECT id FROM usuarios WHERE nombre_usuario = 'tesorero01'),
                    'AUTORIZADO', 2500.00, NULL, '2026-09-20 10:30:00'),
    ('L-2026-09-B', (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
                    NULL, 'PENDIENTE', 8200.00, NULL, NULL),
    ('L-2026-09-C', (SELECT id FROM usuarios WHERE nombre_usuario = 'analista01'),
                    (SELECT id FROM usuarios WHERE nombre_usuario = 'director01'),
                    'RECHAZADO', 3000.00, 'Factura sin orden de compra asociada; se requiere soporte documental.', NULL);

INSERT INTO lote_pago_facturas (lote_id, factura_id, monto_pagado) VALUES
    ((SELECT id FROM lotes_pago WHERE codigo = 'L-2026-09-A'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'ADN150312AB1' AND f.folio_referencia = 'FAC-ABN-0002'), 2500.00),
    ((SELECT id FROM lotes_pago WHERE codigo = 'L-2026-09-B'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'SLU101105QX9' AND f.folio_referencia = 'FAC-SLU-0100'), 8200.00),
    ((SELECT id FROM lotes_pago WHERE codigo = 'L-2026-09-C'),
     (SELECT f.id FROM facturas f JOIN proveedores p ON p.id = f.proveedor_id WHERE p.rfc = 'SLU101105QX9' AND f.folio_referencia = 'FAC-SLU-0101'), 3000.00);

-- Caso de demostracion de borrado logico (nunca DELETE): banco obsoleto marcado estatus = 3.
INSERT INTO bancos (nombre, clave_banco, estatus) VALUES ('Banco Demo Obsoleto', NULL, 3);

COMMIT;
