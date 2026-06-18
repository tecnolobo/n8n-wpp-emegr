# 🛍️ Flujo de Ventas con IA — WhatsApp + n8n + Google Sheets

Agente conversacional por WhatsApp que detecta intención de compra con **GPT-4o-mini**, matchea el producto contra un catálogo en **Google Sheets**, recolecta los datos del cliente paso a paso y registra el pedido automáticamente. Todo orquestado en **n8n**.

> ✨ **Mejoras incluidas en esta versión:**
> 1. **Identificador único por producto** (columna `id`) que se propaga a `sesiones` y `pedidos`.
> 2. **Registro de cancelaciones**: si el cliente cancela un pedido en curso, se guarda en `pedidos` con `estado = cancelado` (los completados quedan `registrado`).
> 3. **Memoria de conversación en PostgreSQL** (nodo *Postgres Chat Memory*, clave = teléfono): la IA recuerda los mensajes previos de cada cliente.
> 4. **`sesiones` migradas a PostgreSQL** (UPSERT atómico por `telefono`): soporta muchos clientes en paralelo **sin condiciones de carrera**. `inventario` y `pedidos` siguen en Google Sheets.

---

## 📦 Contenido del paquete

| Archivo | Descripción |
|---|---|
| `n8n_whatsapp_ventas_workflow.json` | Workflow listo para **importar** en n8n |
| `google_sheets/inventario.csv` | Plantilla del catálogo con datos de ejemplo |
| `google_sheets/pedidos.csv` | Plantilla de pedidos (solo encabezados) |
| `sql/setup_postgres.sql` | Script SQL para crear la tabla `sesiones` en PostgreSQL |

---

## 🧠 Cómo funciona (arquitectura)

```
WhatsApp ──► [Webhook POST] ──► Extraer Mensaje ──► Leer Sesiones ──► Leer Inventario
                                                                              │
                                                                              ▼
                                                                     Construir Contexto
                                                                              │
                                                          ┌───────────────────┴──────────────────┐
                                                          │   AI Agent (GPT-4o-mini)              │
                                                          │   + OpenAI Chat Model                 │
                                                          │   + Parser de Salida (JSON)           │
                                                          └───────────────────┬──────────────────┘
                                                                              ▼
                                                               Procesar Respuesta IA
                                                                              ▼
                                                                     Guardar Sesión
                                                                              ▼
                                                                  ¿Guardar Pedido? ──true──► Registrar Pedido
                                                                              │                      │
                                                                            false                    │
                                                                              └────────► Enviar WhatsApp ◄┘
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
  "registrar_pedido": false,
  "estado_pedido": "registrado",
  "limpiar_sesion": false
}
```

---

## 🚀 Instalación paso a paso

### 1. Crear las tablas en PostgreSQL
1. Levanta PostgreSQL (ver comando Docker más abajo) y ejecuta el script `sql/setup_postgres.sql`. Crea la tabla **`sesiones`** (clave primaria `telefono`).
2. La tabla de memoria **`n8n_chat_histories`** se crea sola en la primera ejecución del nodo *Postgres Chat Memory*.

### 2. Crear los Google Sheets (solo `inventario` y `pedidos`)
1. Crea **un** Google Spreadsheet con **2 hojas** (pestañas).
2. Crea las hojas con estos **nombres exactos** y encabezados en la **fila 1**:

**`inventario`**
| id | producto | valor | descripcion |

**`pedidos`**
| fecha | id_producto | producto | valor | nombre | telefono | direccion | estado |

> ℹ️ Ya **no** existe la hoja `sesiones` en Google Sheets: el estado de conversación vive ahora en la tabla `sesiones` de **PostgreSQL**.

3. Puedes importar los CSV de la carpeta `google_sheets/` (Archivo → Importar) para tener la estructura y datos de ejemplo del catálogo.
4. Copia el **Spreadsheet ID** de la URL: `https://docs.google.com/spreadsheets/d/`**`ESTE_ES_EL_ID`**`/edit`.

### 3. Importar el workflow en n8n
1. En n8n: **Workflows → Import from File** → selecciona `n8n_whatsapp_ventas_workflow.json`.
2. El workflow aparecerá con todos los nodos conectados.

### 4. Configurar credenciales
En los nodos de **Google Sheets** (**Leer Inventario, Registrar Pedido**):
- Selecciona tu credencial **Google Sheets OAuth2**.
- En `Document` → pega tu **Spreadsheet ID**. Reemplaza el placeholder `YOUR_SPREADSHEET_ID` en ambos nodos.
- Verifica que `Sheet` apunte a `inventario` y `pedidos` respectivamente.

En los nodos de **PostgreSQL** (**Leer Sesiones, Guardar Sesion**):
- Selecciona tu credencial **Postgres** (la misma del nodo de memoria).
- Ya traen las consultas SQL listas (SELECT por `telefono` y UPSERT `ON CONFLICT`). No necesitas tocar nada.

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
- ✅ Cliente cancela a mitad (con producto elegido) → se registra en `pedidos` con `estado = cancelado` y la sesión se reinicia.
- ✅ Cliente vuelve a escribir días después → la IA recuerda la conversación previa (memoria Postgres).
- ✅ Varios productos en un mensaje → la IA pide elegir uno (un pedido = un producto).
- ✅ Mensajes fuera de contexto → la IA reencauza la conversación.

---

## 🔧 Notas técnicas
- **Versiones de nodos** usadas: Webhook `v2`, Google Sheets `v4.5`, HTTP Request `v4.2`, Code `v2`, If `v2.2`, AI Agent (LangChain) `v1.7`. Al importar en tu instancia, n8n migra automáticamente si tu versión difiere.
- **Estado:** la sesión se persiste con la operación `Append or Update` de Google Sheets, usando `telefono` como columna de coincidencia (upsert). No se borran filas; al cerrar/cancelar, la IA reinicia la etapa a `inicio` y vacía los campos.
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
- ⚡ Migrar sesiones a Redis si el volumen crece.
