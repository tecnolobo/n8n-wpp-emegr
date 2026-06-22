# 🛍️ Flujo de Ventas con IA — WhatsApp + n8n + Google Sheets

Agente conversacional por WhatsApp que detecta intención de compra con **GPT-4o-mini**, matchea el producto contra un catálogo en **Google Sheets**, recolecta los datos del cliente paso a paso y registra el pedido automáticamente. Todo orquestado en **n8n**.

> ✨ **Mejoras incluidas en esta versión:**
> 1. **Identificador único por producto** (columna `id`, string) que se propaga a `sesiones` y `pedidos`.
> 2. **Cancelación 100% precisa por `pedido_id`**: cada pedido recibe un id único (string, ej. `PED-xxxx`). Al cancelar, se **actualiza esa fila exacta** en `pedidos` cambiando `estado` de `registrado` a `cancelado` (no se crea ni se borra ningún registro, aunque el cliente tenga varios pedidos).
> 3. **Memoria de conversación en PostgreSQL** (nodo *Postgres Chat Memory*): la IA recuerda los mensajes previos de cada cliente.
> 4. **`sesiones` en PostgreSQL** con la columna **`session`** (TEXT) como identificador único del cliente — vale el teléfono en WhatsApp y es compatible con el **PSID alfanumérico de Facebook** a futuro. UPSERT atómico → soporta muchos clientes en paralelo sin condiciones de carrera.
> 5. **Inventario en caché (PostgreSQL)**: el catálogo se lee desde la tabla `inventario` en cada mensaje (rápido). El workflow *Sync Inventario* lo refresca **solo cuando el Google Sheet cambia**.
> 6. **Imágenes de producto**: cada producto puede tener **una o varias imágenes** (columna `imagenes`, URLs separadas por `|`). Cuando el cliente pide una foto, el bot envía una; si pide **más**, envía la siguiente **que aún no le compartió**, y avisa cuando se acaban.

---

## 📦 Contenido del paquete

| Archivo | Descripción |
|---|---|
| `n8n_whatsapp_ventas_workflow.json` | Workflow principal (conversación) listo para **importar** en n8n |
| `n8n_sync_inventario_workflow.json` | Workflow de **sincronización** del inventario (Sheets → Postgres) |
| `google_sheets/inventario.csv` | Plantilla del catálogo con datos de ejemplo |
| `google_sheets/pedidos.csv` | Plantilla de pedidos (solo encabezados) |
| `sql/setup_postgres.sql` | Script SQL para crear las tablas `sesiones` e `inventario` en PostgreSQL |

---

## 🧠 Cómo funciona (arquitectura)

```
                      (PostgreSQL cache)        (workflow aparte: Sync Inventario)
                       tabla inventario  ◄──────  Google Sheet inventario (al cambiar)

WhatsApp ──► [Webhook POST] ──► Extraer Mensaje ──► Leer Sesiones(PG) ──► Leer Inventario(PG)
                                                                              │
                                                                              ▼
                                                                     Construir Contexto
                                                                              │
                                                          ┌───────────────────┴──────────────────┐
                                                          │   AI Agent (GPT-4o-mini)              │
                                                          │   + OpenAI Chat Model                 │
                                                          │   + Postgres Chat Memory              │
                                                          │   + Parser de Salida (JSON)           │
                                                          └───────────────────┬──────────────────┘
                                                                              ▼
                                                               Procesar Respuesta IA
                                                                              ▼
                                                                 Guardar Sesión (UPSERT PG)
                                                                              ▼
                                                          ┌──────── Switch: accion_pedido ────────┐
                                                  crear ──►│  Registrar Pedido (append, registrado)│
                                               cancelar ──►│  Cancelar Pedido (update -> cancelado)│
                                                ninguna ──►│  (nada)                               │
                                                          └───────────────────┬──────────────────┘
                                                                              ▼
                                                                        Enviar WhatsApp
```

**Decisión de diseño clave:** en lugar de un `Switch` rígido con una rama por etapa, el **AI Agent maneja toda la máquina de estados**. Recibe el catálogo + el estado actual de la sesión + el mensaje nuevo, y devuelve un JSON estructurado que indica la **siguiente etapa**, los **datos acumulados**, la **respuesta al cliente** y si se debe **guardar el pedido**. Esto es mucho más robusto frente a clientes indecisos, mensajes fuera de contexto o varios productos en un mensaje.

### Etapas de la conversación
`inicio` → `confirmar_producto` → `pedir_nombre` → `pedir_direccion` → `confirmar_pedido` → `cerrado`

El cliente puede **cancelar** o **empezar de nuevo** en cualquier momento (la IA limpia la sesión).

### JSON que devuelve la IA
```json
{
  "etapa": "confirmar_producto",
  "producto_id": "P001",
  "producto_seleccionado": "Camisa Blanca",
  "valor": 25000,
  "nombre": "",
  "direccion": "",
  "respuesta": "Sí, tenemos *Camisa Blanca* por *$25.000*. ¿Deseas pedirla?",
  "accion_pedido": "ninguna",
  "limpiar_sesion": false
}
```

> El campo **`accion_pedido`** controla la hoja `pedidos`:
> - `crear` → agrega una fila nueva con `estado = registrado` y un `pedido_id` único (al confirmar un pedido).
> - `cancelar` → **actualiza** la fila exacta (match por `pedido_id`, recordado en la sesión) cambiando `estado` a `cancelado`. No crea ni borra filas.
> - `ninguna` → no toca `pedidos` (incluye abandonar un pedido aún no confirmado).

---

## 🚀 Instalación paso a paso

### 1. Crear las tablas en PostgreSQL
1. Levanta PostgreSQL (ver comando Docker más abajo) y ejecuta el script `sql/setup_postgres.sql`. Crea las tablas **`sesiones`** (clave `telefono`) e **`inventario`** (caché del catálogo, clave `id`).
2. La tabla de memoria **`n8n_chat_histories`** se crea sola en la primera ejecución del nodo *Postgres Chat Memory*.

### 2. Crear los Google Sheets (solo `inventario` y `pedidos`)
1. Crea **un** Google Spreadsheet con **2 hojas** (pestañas).
2. Crea las hojas con estos **nombres exactos** y encabezados en la **fila 1**:

**`inventario`**
| id | producto | valor | descripcion | imagenes |

> 🖼️ La columna **`imagenes`** admite **una o varias URLs públicas** de imagen separadas por `|` (también acepta coma o salto de línea). Ej: `https://.../foto1.jpg | https://.../foto2.jpg`. Deben ser **URLs directas y públicas** (WhatsApp las descarga); un enlace de "compartir" de Google Drive **no** funciona como imagen directa — usa el formato `https://drive.google.com/uc?export=view&id=FILE_ID` o un bucket/CDN público.

**`pedidos`**
| fecha | id_producto | producto | valor | nombre | telefono | direccion | estado |

> ℹ️ Ya **no** existe la hoja `sesiones` en Google Sheets: el estado de conversación vive ahora en la tabla `sesiones` de **PostgreSQL**.

3. Puedes importar los CSV de la carpeta `google_sheets/` (Archivo → Importar) para tener la estructura y datos de ejemplo del catálogo.
4. Copia el **Spreadsheet ID** de la URL: `https://docs.google.com/spreadsheets/d/`**`ESTE_ES_EL_ID`**`/edit`.

### 3. Importar los workflows en n8n
1. **Workflows → Import from File** → importa `n8n_whatsapp_ventas_workflow.json` (flujo principal).
2. Importa también `n8n_sync_inventario_workflow.json` (sincronización de inventario).

### 4. Configurar credenciales

**Flujo principal — nodos de Google Sheets** (**Registrar Pedido, Cancelar Pedido**):
- Selecciona tu credencial **Google Sheets OAuth2** y pega tu **Spreadsheet ID** (reemplaza `YOUR_SPREADSHEET_ID`). Ambos apuntan a la hoja `pedidos`.

**Flujo principal — nodos de PostgreSQL** (**Leer Sesiones, Leer Inventario, Guardar Sesion**):
- Selecciona tu credencial **Postgres** (la misma de la memoria).
- Ya traen el SQL listo (SELECT sesión por `telefono`, SELECT del catálogo desde `inventario`, y UPSERT de sesión). No hay que tocar nada.

**Workflow Sync Inventario** (`n8n_sync_inventario_workflow.json`):
- Nodo *Trigger - Cambio Inventario* y *Leer Inventario (Sheets)*: credencial **Google Sheets** + `Spreadsheet ID`, hoja `inventario`.
- Nodos *Upsert Inventario* y *Eliminar Borrados*: credencial **Postgres**.
- **Ejecuta una vez** el trigger manual (*Primera Carga*) para llenar la tabla `inventario`, luego **activa** el workflow para que se sincronice automáticamente cuando el Sheet cambie.

> ⚡ **Por qué dos workflows:** el principal lee el catálogo desde Postgres en cada mensaje (rápido, sin límites de Sheets). El de sincronización solo toca Google Sheets cuando el inventario cambia.

En el nodo **OpenAI Chat Model**:
- Selecciona tu credencial **OpenAI** (tu API key). Modelo: `gpt-4o-mini`.

En el nodo **Postgres Chat Memory** (memoria de conversación):
- Selecciona tu credencial **Postgres** (host, puerto, base de datos, usuario, contraseña).
- `Table Name`: `n8n_chat_histories` (la tabla se crea sola en la primera ejecución).
- `Session Key`: ya viene como `{{ $('Construir Contexto').first().json.telefono }}` → una memoria independiente por cada teléfono.
- `Context Window Length`: `15` (cuántos mensajes recuerda; ajústalo según necesites).

> 🐘 **PostgreSQL con Docker** (si lo necesitas en tu VPS):
> ```bash
> docker run -d --name postgres-n8n \
>   -e POSTGRES_USER=n8n \
>   -e POSTGRES_PASSWORD=tu_password \
>   -e POSTGRES_DB=n8n_memory \
>   -p 5432:5432 \
>   -v pgdata:/var/lib/postgresql/data \
>   postgres:16
> ```
> Si n8n y Postgres están en el mismo `docker-compose`, usa el nombre del servicio (ej. `postgres-n8n`) como host en la credencial.

En el nodo **Enviar WhatsApp**:
- Crea una credencial **Header Auth** (`httpHeaderAuth`):
  - **Name:** `Authorization`
  - **Value:** `Bearer EL_TOKEN_DE_WHATSAPP_CLOUD_API`
- Asigna esa credencial al nodo.

> 💡 El `phone_number_id` se toma automáticamente del payload entrante de Meta, por lo que la URL de envío se arma sola. Si prefieres fijarlo, edita la URL del nodo **Enviar WhatsApp**.

### 4. Configurar el Webhook en Meta
1. **Activa** el workflow en n8n (toggle arriba a la derecha) para tener las **Production URLs**.
2. Copia la **Production URL** del nodo **Webhook Verificación / Mensajes**. Será algo como:
   `https://TU-DOMINIO/webhook/whatsapp`
3. En **Meta for Developers → tu App → WhatsApp → Configuration → Webhooks**:
   - **Callback URL:** `https://TU-DOMINIO/webhook/whatsapp`
   - **Verify token:** el que quieras (por ejemplo `mi_token_secreto`).
   - Meta hará un **GET** de verificación → el workflow responde el `hub.challenge` automáticamente.
4. **Suscríbete** al campo `messages`.

> ⚠️ Sobre el *verify token*: el nodo actual responde el challenge directamente. Si quieres **validar** que el token coincida, añade un nodo `IF` después de **Webhook Verificación** comparando `{{ $json.query['hub.verify_token'] }}` con tu token antes de **Responder Challenge**.

### 5. ¡Probar!
1. Escribe desde tu WhatsApp al número de prueba: *"¿Tienen camisas blancas?"*
2. El bot debe responder confirmando el producto y precio.
3. Confirma → da tu nombre → da tu dirección → confirma el pedido.
4. Revisa la hoja **`pedidos`**: debe aparecer la nueva fila. La sesión queda lista para una nueva compra.

---

## 🧪 Casos de prueba sugeridos (Fase 6)
- ✅ Cliente indeciso (pregunta varias veces antes de decidir).
- ✅ Producto inexistente → la IA pide aclaración o sugiere alternativas.
- ✅ Cliente cancela a mitad, **antes de confirmar** → `accion_pedido = ninguna`, solo se reinicia la sesión (no había pedido que cancelar).
- ✅ Cliente cancela un pedido **ya registrado** → la fila existente en `pedidos` pasa de `registrado` a `cancelado` (no se crea otra fila).
- ✅ Cliente vuelve a escribir días después → la IA recuerda la conversación previa (memoria Postgres).
- ✅ Varios productos en un mensaje → la IA pide elegir uno (un pedido = un producto).
- ✅ Cliente pide una foto → recibe una imagen del producto. Pide **otra/más** → recibe la siguiente no compartida. Cuando se acaban → el bot avisa que no hay más.
- ✅ Mensajes fuera de contexto → la IA reencauza la conversación.

---

## 🔧 Notas técnicas
- **Versiones de nodos** usadas: Webhook `v2`, Google Sheets `v4.5`, Postgres `v2.6`, HTTP Request `v4.2`, Code `v2`, Switch `v3.2`, AI Agent (LangChain) `v1.7`. Al importar, n8n migra automáticamente si tu versión difiere.
- **Sesiones e inventario en PostgreSQL:** la sesión se persiste con `INSERT ... ON CONFLICT (telefono) DO UPDATE` (UPSERT atómico). El catálogo se lee de la tabla `inventario` (caché), que el workflow *Sync Inventario* mantiene al día desde Google Sheets.
- **Cancelación = UPDATE por `pedido_id`:** al registrar un pedido se genera un `pedido_id` único (string) que se guarda en `pedidos` y en `sesiones.ultimo_pedido_id`. El nodo *Cancelar Pedido* usa la operación `update` de Google Sheets matcheando por `pedido_id`, así cancela exactamente el pedido correcto aunque el cliente tenga varios.
- **Identificador de cliente (`session`):** la tabla `sesiones` usa la columna `session` (TEXT) como clave. Hoy contiene el teléfono de WhatsApp; mañana puede contener el PSID alfanumérico de Facebook Messenger sin cambiar el esquema.
- **Imágenes:** el bot detecta el pedido de fotos con el campo `enviar_imagen` de la IA y, en el nodo *Procesar Respuesta IA*, calcula la **siguiente imagen no enviada** del producto (lista de la columna `imagenes`). Lleva la cuenta en la sesión (`img_producto_id` + `img_index`); si cambias de producto, el contador se reinicia. El mensaje saliente se arma como tipo `image` (con caption) o `text` según corresponda, y se envía por el **mismo** nodo *Enviar WhatsApp*.
- **Mensajes no-texto** (status, imágenes, audios) se ignoran en el nodo `Extraer Mensaje`.
- **API de Meta:** se usa `graph.facebook.com/v21.0`. Actualiza la versión si Meta lo requiere.

---

## 🌱 Mejoras futuras (backlog)
- 🛒 Carrito de múltiples productos por pedido.
- 📦 Validación de stock (columna `stock` + descuento al confirmar).
- 🔔 Notificación a tu WhatsApp/Email cuando entra un pedido.
- 🖼️ Envío de imagen del producto al confirmar.
- 💳 Integración con pasarela de pago (Stripe / Mercado Pago link).
- 📊 Dashboard de pedidos en vez de solo Sheets.
- 💬 Soporte de **Facebook Messenger** (reutilizando la columna `session` para el PSID).
con historial.
