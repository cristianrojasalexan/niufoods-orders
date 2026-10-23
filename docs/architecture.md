# Arquitectura

Este documento describe los componentes del sistema, el modelo de datos y el recorrido de una orden desde que llega por la API hasta que la recibe la tienda.

> Describe la solución tal como quedó implementada. El detalle del despacho (claim, reintentos, recuperación y reintento manual) está en [Despacho a tienda](dispatch.md).

- [Componentes](#componentes)
- [Modelo de datos](#modelo-de-datos)
- [Flujo de una orden](#flujo-de-una-orden)

## Componentes

```mermaid
flowchart TB
    subgraph channels["① Canales digitales"]
        direction LR
        app["App / Web"]
        sim["script/simulate_orders.rb"]
    end

    subgraph rails["② API central · Ruby on Rails"]
        direction LR
        api["API REST<br/>POST /api/v1/orders"]
        create["Orders::Create<br/>validación + cálculo de total"]
        dash["Dashboard y panel Tiendas<br/>Hotwire + Tailwind"]
    end

    subgraph infra["③ Persistencia y cola"]
        direction LR
        pg[("PostgreSQL<br/>órdenes · ítems · intentos<br/>estado de despacho")]
        redis[("Redis<br/>cola de jobs")]
    end

    subgraph async["④ Segundo plano"]
        direction LR
        worker["Sidekiq<br/>DispatchOrderJob"]
        recovery["bin/dispatch_recovery<br/>retoma despachos pendientes"]
    end

    subgraph stores["⑤ Tiendas de destino"]
        direction LR
        prov["Providencia · PROV"]
        lcon["Las Condes · LCON"]
        nuno["Ñuñoa · NUNO"]
    end

    app -- "JSON" --> api
    sim -- "JSON" --> api
    api --> create
    create -- "orden + ítems (transacción)" --> pg
    create -. "encola tras el commit" .-> redis
    dash -- "lee las órdenes;<br/>cambia el modo de las tiendas" --> pg
    redis -. "entrega el job" .-> worker
    worker -- "claim / resultado" --> pg
    recovery -- "busca pendientes" --> pg
    recovery -. "reencola" .-> redis
    worker == "POST HTTP + Idempotency-Key" ==> lcon

    classDef channel fill:#fde2ec,stroke:#e0457b,color:#5a1030
    classDef railsApp fill:#fbe3e3,stroke:#cc342d,color:#5c1411
    classDef storage fill:#e3ecf7,stroke:#336791,color:#13304d
    classDef job fill:#fff1dc,stroke:#d9822b,color:#5a3200
    classDef store fill:#e6f4ea,stroke:#2e7d4f,color:#123d24

    class app,sim channel
    class api,create,dash railsApp
    class pg,redis storage
    class worker,recovery job
    class prov,lcon,nuno store

    style channels fill:#fff7fa,stroke:#e0457b,stroke-dasharray:4 3
    style rails fill:#fff6f5,stroke:#cc342d,stroke-dasharray:4 3
    style infra fill:#f5f8fc,stroke:#336791,stroke-dasharray:4 3
    style async fill:#fffaf2,stroke:#d9822b,stroke-dasharray:4 3
    style stores fill:#f4faf6,stroke:#2e7d4f,stroke-dasharray:4 3
```

| Componente | Responsabilidad |
|---|---|
| **API REST** (`Api::V1::OrdersController`) | Recibe el JSON, aplica strong params y traduce el resultado a una respuesta HTTP (201, 200, 400, 404, 409, 422). |
| **`Orders::Create`** | Valida la orden, calcula el total con los precios de la base de datos y guarda la orden y sus ítems en una sola transacción. |
| **PostgreSQL** | Fuente de verdad de las órdenes **y del estado de despacho**: intentos, próximo intento y lease del worker activo. |
| **Redis + Sidekiq** | Ejecutan el despacho en segundo plano. Sidekiq no decide cuántas veces reintentar; eso lo controla PostgreSQL. |
| **`bin/dispatch_recovery`** | Proceso periódico que retoma las órdenes que quedaron sin job, por ejemplo si Redis falló justo después de guardar la orden o si un worker murió a mitad de un despacho. |
| **Tiendas** | Reciben la orden por HTTP. En esta solución se simulan con un endpoint aislado dentro de la app (`/simulated_stores/:code/orders`). En producción serían sistemas externos y bastaría con cambiar `dispatch_url`. La página **Tiendas** (`/stores`), que es parte del dashboard, muestra cómo responde cada una y lo que recibió, y cambia su modo. |
| **Dashboard** | Muestra las órdenes con filtros y búsqueda, el resumen del día, las órdenes con error y el detalle de cada una con sus intentos de despacho como línea de tiempo, y permite reintentar manualmente un despacho fallido. Se actualiza solo con el *morphing* de Turbo: cada 3 s mientras hay despachos en curso y cada 15 s si no. |

Las flechas punteadas son comunicación asíncrona a través de la cola. La flecha gruesa es la entrega HTTP a la tienda de destino de cada orden; en el diagrama se dibuja hacia Las Condes, pero cada orden va a la tienda indicada en su `restaurant_id`.

## Modelo de datos

```mermaid
erDiagram
    RESTAURANTS ||--o{ ORDERS : "recibe"
    ORDERS ||--|{ ORDER_ITEMS : "contiene"
    PRODUCTS ||--o{ ORDER_ITEMS : "aparece en"
    ORDERS ||--o{ DISPATCH_ATTEMPTS : "registra"

    RESTAURANTS {
        bigint id PK
        string name
        string code UK "PROV, LCON, NUNO"
        string dispatch_url
    }

    PRODUCTS {
        bigint id PK
        string name
        string sku UK
        integer price "CLP, sin decimales"
    }

    ORDERS {
        bigint id PK
        string number UK "ej. LCON-000042"
        bigint restaurant_id FK
        string order_type "pickup | delivery"
        string customer_name
        string customer_phone
        string delivery_address "obligatoria si es delivery"
        integer total_amount "calculado en el servidor"
        string idempotency_key UK "opcional, único si existe"
        string request_fingerprint "SHA-256 de la solicitud canónica"
        string dispatch_status "pending | dispatching | dispatched | failed"
        integer dispatch_cycle
        integer dispatch_attempts_count
        datetime next_dispatch_at
        uuid dispatch_token
        datetime dispatch_lease_expires_at
        datetime dispatched_at
        string last_dispatch_error
    }

    ORDER_ITEMS {
        bigint id PK
        bigint order_id FK
        bigint product_id FK
        integer quantity "entre 1 y 99"
        integer unit_price "precio congelado"
        integer subtotal "unit_price × quantity"
    }

    DISPATCH_ATTEMPTS {
        bigint id PK
        bigint order_id FK
        integer dispatch_cycle
        integer attempt_number
        uuid dispatch_token
        string outcome "success | transient | permanent | stale"
        integer http_status
        string error_message
        integer duration_ms
    }
```

**Decisiones del modelo:**

- **Montos en enteros.** El peso chileno no usa decimales, así que precios y totales son `integer`. Se evitan los errores de redondeo de los `float`.
- **Precio congelado en cada ítem.** `order_items.unit_price` guarda el precio vigente al crear la orden. Si después cambia el catálogo, el total de las órdenes ya guardadas no cambia.
- **Un producto por orden aparece una sola vez.** Hay un índice único en `(order_id, product_id)`. Si el payload repite un producto, sus cantidades se suman en un solo ítem.
- **Integridad en la base de datos, no solo en Rails.** Claves foráneas, columnas `NOT NULL` y restricciones `CHECK` protegen los datos aunque alguien escriba sin pasar por los modelos: `quantity > 0`, `subtotal = unit_price * quantity`, `total_amount >= 0`, tipo de pedido válido y dirección obligatoria en delivery.
- **Total derivado de los ítems.** `total_amount` es la suma de los subtotales por cualquier camino de escritura a través de los modelos (SQL directo lo salta, como la regla de abajo sobre los ítems): `Order` lo calcula antes de validar con los ítems en memoria (así un total asignado desde afuera no se guarda y se puede comparar con el que envía el cliente) y guarda los ítems modificados junto con la orden (`autosave`). Como esos ítems en memoria pueden estar desactualizados si otro proceso cambió uno después de cargarlos, al terminar de guardar la orden el total se vuelve a calcular en SQL, con la orden bloqueada. Lo mismo ocurre cuando un ítem se crea, modifica o elimina por separado. Antes de escribir un ítem se bloquea la fila de la orden (`SELECT ... FOR UPDATE`), así que dos cambios simultáneos sobre la misma orden se serializan y el segundo calcula la suma con el primero ya confirmado.
- **Orden de bloqueo: siempre la orden antes que sus ítems.** Lo respetan la modificación de un ítem, `order.save!` (actualiza la orden y después los ítems) y `order.destroy!`, que bloquea la orden antes de la cascada de `dependent: :destroy`. Al usar un orden único se evitan deadlocks entre esos caminos. Si una modificación de ítem esperaba el lock de una orden que se eliminó, lanza `ActiveRecord::RecordNotFound` en vez de actualizar cero filas en silencio. Un ítem nuevo siempre toma el precio del catálogo, aunque se le haya asignado otro.
- **Una orden siempre tiene al menos un ítem.** Además de la validación en memoria, la cantidad se comprueba en la base con la orden bloqueada: al eliminar un ítem por separado, debe quedar otro; al guardar la orden, se revisa la cantidad final después de escribir los ítems, así que reemplazar el último ítem en un mismo guardado (marcarlo con `mark_for_destruction` y agregar otro) está permitido. Sí se puede eliminar la orden completa. A diferencia de las restricciones `CHECK`, esta regla la aplican los modelos y no PostgreSQL, así que `delete_all` o SQL directo la saltan. Llevarla a la base requeriría un trigger diferido, que `schema.rb` no guarda.
- **Un ítem no cambia de orden ni de producto.** `order_id` y `product_id` son de solo lectura una vez creado el ítem: moverlo dejaría desactualizado el total de la orden original, y cambiar su producto mantendría el precio del anterior. Para eso se elimina el ítem y se agrega otro.
- **Hasta 99 unidades por producto.** Es un límite de negocio razonable para una orden de restaurante y evita montos fuera de rango.
- **Número de orden legible.** El formato es `<código de tienda>-<id con 6 dígitos>` (por ejemplo, `LCON-000042`). El `id` se reserva desde la secuencia de la tabla antes de insertar, así que el número se guarda en el mismo `INSERT` y es único aunque lleguen órdenes en paralelo.
- **Despacho auditable.** Cada intento de entrega queda en `dispatch_attempts`, con su resultado, el código HTTP y la duración. El dashboard muestra ese historial.
- **IDs fijos en el catálogo.** Restaurantes (1 a 3) y productos (1 a 10) usan los IDs del dataset de la prueba, porque el payload los referencia directamente.

La tienda simulada guarda su propio estado en tablas separadas (`simulated_store_modes` y `simulated_store_requests`) que no se relacionan con el dominio de órdenes. Se describen en [Tiendas simuladas](simulated_stores.md).

## Flujo de una orden

```mermaid
sequenceDiagram
    autonumber
    actor C as Canal / script
    participant API as API Rails
    participant SVC as Orders::Create
    participant DB as PostgreSQL
    participant Q as Redis
    participant W as Sidekiq worker
    participant S as Tienda

    rect rgb(253, 236, 242)
    Note over C,DB: Recepción, validación y persistencia (síncrono)
    C->>+API: POST /api/v1/orders (JSON)
    API->>API: strong params
    API->>+SVC: payload normalizado
    SVC->>DB: restaurante y productos existen
    SVC->>SVC: calcula total con precios de la DB
    alt payload inválido
        SVC-->>API: errores
        API-->>C: 422 con detalle por campo
    else payload válido
        SVC->>DB: BEGIN · orden + ítems · COMMIT
        SVC->>Q: encola DispatchOrderJob (tras el commit)
        SVC-->>-API: orden creada
        API-->>-C: 201 Created (dispatch_status = pending)
    end
    end

    rect rgb(255, 244, 228)
    Note over Q,S: Despacho a tienda (segundo plano)

    Q->>+W: DispatchOrderJob(order_id)
    W->>DB: claim atómico → dispatching + token
    W->>+S: POST dispatch_url (Idempotency-Key = número de orden)
    alt 2xx
        S-->>W: recibida
        W->>DB: dispatched (si el token sigue vigente)
    else error transitorio (5xx, 408, 425, 429, timeout)
        S-->>W: error
        W->>DB: pending + next_dispatch_at
        W->>Q: reprograma con espera exponencial
    else error permanente (otros 4xx) o intentos agotados
        S-->>-W: rechazo
        W->>DB: failed
    end
    deactivate W
    end
```

1. **Recepción.** El controlador acepta exactamente el payload del enunciado y filtra los campos con strong params.
2. **Validación.** `Orders::Create` comprueba que el restaurante y los productos existan, que las cantidades sean enteros positivos y que una orden delivery traiga dirección.
3. **Cálculo y persistencia.** El total se calcula con los precios de la base de datos y no con el que informa el cliente. La orden y sus ítems se guardan en una sola transacción: o queda todo o no queda nada.
4. **Encolado.** El job se encola **después del commit**, para que el worker no busque una orden que todavía no es visible en la base. Si Redis no responde, la orden igual queda guardada como `pending` y el proceso de recuperación la toma cuando el servicio vuelve.
5. **Despacho.** El worker reclama la orden de forma atómica, la envía a la tienda y registra el resultado. Los errores transitorios se reintentan con espera exponencial, hasta un máximo de intentos por ciclo controlado en PostgreSQL. Los permanentes marcan la orden como `failed` y se pueden reintentar a mano desde el dashboard.
