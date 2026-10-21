# API de órdenes · v1

API JSON para recibir órdenes desde los canales digitales y consultar su estado.

- [Crear una orden](#crear-una-orden) · `POST /api/v1/orders`
- [Consultar una orden](#consultar-una-orden) · `GET /api/v1/orders/:id`
- [Errores](#errores)

Todas las respuestas son `application/json`. Los montos están en pesos chilenos (CLP) y son enteros, porque el CLP no usa decimales.

## Crear una orden

```
POST /api/v1/orders
Content-Type: application/json
```

### Request

Es el payload de referencia de la prueba, plano y sin envoltorio:

```json
{
  "restaurant_id": 2,
  "order_type": "delivery",
  "customer": {
    "name": "Ana Pérez",
    "phone": "+56912345678"
  },
  "delivery_address": "Av. Providencia 1234, Santiago",
  "items": [
    { "product_id": 1, "quantity": 2 },
    { "product_id": 5, "quantity": 1 }
  ]
}
```

| Campo | Tipo | Obligatorio | Reglas |
|---|---|---|---|
| `restaurant_id` | entero | sí | Entero positivo de un restaurante existente. |
| `order_type` | string | sí | `pickup` (retiro) o `delivery`. |
| `customer.name` | string | sí | Se eliminan los espacios al inicio y al final. |
| `customer.phone` | string | sí | `+` opcional seguido de 8 a 15 dígitos. Se aceptan espacios, guiones y paréntesis, que se eliminan al guardar. |
| `delivery_address` | string | solo en `delivery` | En una orden `pickup` se ignora y no se guarda. |
| `items` | array | sí | Al menos un elemento. |
| `items[].product_id` | entero | sí | Entero positivo de un producto existente. |
| `items[].quantity` | entero | sí | De 1 a 99. |
| `total_amount` | entero | no | Si se envía, tiene que coincidir con el total que calcula el servidor. |

**Reglas importantes:**

- **El total lo calcula el servidor** con los precios del catálogo. `total_amount` es opcional y solo sirve para que el cliente confirme que calculó lo mismo; si no coincide, la orden se rechaza con `total_mismatch`.
- **Los tipos se validan tal como vienen en el JSON**, antes de cualquier conversión. Una cantidad `2.5`, `2.0` o `"2"` se rechaza; nunca se trunca ni se convierte.
- **Los productos repetidos se suman.** `[{product_id: 1, quantity: 1}, {product_id: 1, quantity: 2}]` genera un solo ítem con cantidad 3. El límite de 99 unidades aplica al total de cada producto.
- **Los campos fuera del contrato se ignoran**, por ejemplo un `unit_price` o un `number` enviados por el cliente. En cambio, un campo del contrato con forma incorrecta (un ítem que no es objeto, un total enviado como array) rechaza la orden completa: nunca se acepta con datos parciales.
- **La orden y sus ítems se guardan en una sola transacción.** O queda todo guardado o no queda nada.

### Respuesta `201 Created`

Incluye el header `Location` con la URL de la orden. El cuerpo tiene la misma forma que el request (`customer` anidado) y agrega lo que calculó el servidor:

```json
{
  "id": 9,
  "number": "LCON-000009",
  "restaurant": { "id": 2, "code": "LCON", "name": "Niu Foods Las Condes" },
  "order_type": "delivery",
  "customer": { "name": "Ana Pérez", "phone": "+56912345678" },
  "delivery_address": "Av. Providencia 1234, Santiago",
  "items": [
    { "product_id": 1, "sku": "SKU-001", "name": "Niu Roll Salmón", "quantity": 2, "unit_price": 8990, "subtotal": 17980 },
    { "product_id": 5, "sku": "SKU-005", "name": "Gyozas de Pollo x5", "quantity": 1, "unit_price": 4490, "subtotal": 4490 }
  ],
  "total_amount": 22470,
  "currency": "CLP",
  "created_at": "2026-10-21T17:05:16Z"
}
```

- `number` combina el código de la tienda con el `id` de la orden.
- `unit_price` es el precio que tenía el producto al crear la orden; si el catálogo cambia después, el valor no cambia.
- `created_at` está en UTC (ISO 8601).

### Ejemplo con curl

```bash
curl -i -X POST http://localhost:3000/api/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{"restaurant_id":2,"order_type":"delivery","customer":{"name":"Ana Pérez","phone":"+56912345678"},"delivery_address":"Av. Providencia 1234, Santiago","items":[{"product_id":1,"quantity":2},{"product_id":5,"quantity":1}]}'
```

## Consultar una orden

```
GET /api/v1/orders/:id
```

Devuelve `200 OK` con la misma representación de la creación, o `404` si la orden no existe.

```bash
curl http://localhost:3000/api/v1/orders/9
```

## Errores

Todos los errores tienen la misma forma, así que el cliente maneja un solo formato:

```json
{
  "errors": [
    { "field": "items[0].quantity", "code": "invalid_quantity", "message": "must be an integer between 1 and 99" }
  ]
}
```

- `field` usa los nombres del request, como `customer.name` o `items[1].product_id`, con la posición del ítem tal como se envió. Es `null` cuando el error no corresponde a un campo.
- `code` es estable y está pensado para que lo lea un programa; `message` está pensado para personas y puede cambiar.

### Códigos de respuesta

| Status | Cuándo |
|---|---|
| `201 Created` | La orden se creó. |
| `200 OK` | Consulta de una orden. |
| `400 Bad Request` | El body no se puede procesar: JSON inválido, vacío o que no es un objeto. |
| `404 Not Found` | La orden consultada no existe. |
| `422 Unprocessable Content` | El JSON es válido, pero la orden no cumple las reglas. |

### Códigos de error

| `code` | Status | Significado |
|---|---|---|
| `malformed_json` | 400 | El body no es JSON válido. |
| `missing_payload` | 400 | El body está vacío o no trae la orden. |
| `invalid_payload` | 400 | La raíz de la orden no es un objeto JSON. |
| `not_found` | 404 | La orden consultada no existe. |
| `blank` | 422 | Falta un campo obligatorio. |
| `invalid_type` | 422 | El campo tiene un tipo distinto al del contrato (por ejemplo, un string donde va un entero). |
| `invalid_quantity` | 422 | La cantidad no es un entero entre 1 y 99, o un producto suma más de 99 unidades. |
| `not_found` | 422 | El restaurante o el producto indicado no existe. |
| `inclusion` | 422 | `order_type` no es `pickup` ni `delivery`. |
| `invalid` | 422 | El formato no es válido, por ejemplo un teléfono que no son dígitos. |
| `total_mismatch` | 422 | El `total_amount` enviado no coincide con el calculado; el mensaje indica el total correcto. |

### Orden de las validaciones

Las validaciones se hacen en dos etapas, y la segunda solo corre si la primera no encontró problemas:

1. **Forma y tipos del payload.** Se informan todos los problemas juntos en una sola respuesta.
2. **Catálogo y reglas de negocio.** Restaurante y productos existentes, dirección en delivery, datos del cliente y, al final, el total.

Por eso, un request con una cantidad `2.5` y sin dirección de delivery responde primero solo el error de la cantidad.

### Ejemplos

Producto inexistente:

```json
{ "errors": [ { "field": "items[1].product_id", "code": "not_found", "message": "does not exist" } ] }
```

Total enviado que no coincide:

```json
{ "errors": [ { "field": "total_amount", "code": "total_mismatch", "message": "does not match the calculated total of 22470" } ] }
```

JSON inválido:

```json
{ "errors": [ { "field": null, "code": "malformed_json", "message": "the request body is not valid JSON" } ] }
```
