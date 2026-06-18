-- ============================================================
--  Setup PostgreSQL para el flujo de ventas IA (n8n)
--  Ejecuta este script UNA vez en tu base de datos.
-- ============================================================

-- Tabla de SESIONES (estado de conversacion por cliente)
-- La clave primaria es el telefono -> permite UPSERT atomico (sin condiciones de carrera).
CREATE TABLE IF NOT EXISTS sesiones (
    telefono              TEXT PRIMARY KEY,
    etapa                 TEXT        NOT NULL DEFAULT 'inicio',
    producto_id           TEXT        DEFAULT '',
    producto_seleccionado TEXT        DEFAULT '',
    valor                 NUMERIC     DEFAULT 0,
    nombre                TEXT        DEFAULT '',
    direccion             TEXT        DEFAULT '',
    actualizado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sesiones_actualizado ON sesiones (actualizado_en);

-- Tabla de INVENTARIO (cache del catalogo en Postgres)
-- El workflow "Sync Inventario" la mantiene sincronizada desde Google Sheets
-- SOLO cuando el inventario cambia (o en la primera carga manual).
-- El flujo principal lee el catalogo desde aqui (rapido), no desde Sheets en cada mensaje.
CREATE TABLE IF NOT EXISTS inventario (
    id          TEXT PRIMARY KEY,
    producto    TEXT    NOT NULL,
    valor       NUMERIC DEFAULT 0,
    descripcion TEXT    DEFAULT ''
);

-- ============================================================
--  Nota: la tabla de MEMORIA de conversacion (n8n_chat_histories)
--  la crea automaticamente el nodo "Postgres Chat Memory" de n8n
--  en su primera ejecucion. No necesitas crearla a mano.
-- ============================================================

-- (Opcional) Limpieza de sesiones abandonadas con mas de 24h sin actividad:
-- DELETE FROM sesiones WHERE actualizado_en < NOW() - INTERVAL '24 hours';
