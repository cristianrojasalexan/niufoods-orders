# Simulación de órdenes

`script/simulate_orders.rb` simula los canales digitales: genera órdenes con el dataset de productos de la prueba y las envía a la API, mezclando órdenes inválidas a propósito para comprobar que se rechazan.

```bash
ruby script/simulate_orders.rb                                   # 20 órdenes, ~20 % inválidas
ruby script/simulate_orders.rb --count 50 --invalid-ratio 0.3   # más órdenes y más inválidas
ruby script/simulate_orders.rb --seed 42                         # repite exactamente las mismas órdenes
ruby script/simulate_orders.rb --url http://localhost:3000       # otra URL (o SIMULATION_URL)
```

| Opción | Default | Uso |
|---|---|---|
| `--url` | `http://localhost:3000` | URL base de la API. También se puede definir con `SIMULATION_URL`. |
| `--count` | `20` | Cantidad de órdenes a enviar. |
| `--invalid-ratio` | `0.2` | Proporción de órdenes inválidas, entre 0 y 1. |
| `--seed` | aleatoria | Semilla. La corrida la muestra al inicio, así que cualquier resultado se puede repetir. |

## Qué hace

- **Ruby puro, sin Rails:** usa `net/http`, `json` y `optparse`, y habla con la API por HTTP como cualquier cliente externo.
- **Usa el mismo dataset que las seeds** (`db/data/products.json` y `db/data/restaurants.json`), así que los IDs y precios coinciden con los de la base.
- **Órdenes válidas** con la forma exacta del payload de referencia (`customer` anidado):
  - restaurante al azar entre los 3 del dataset;
  - `pickup` o `delivery`, con dirección solo en delivery;
  - de 1 a 5 productos distintos, con cantidades de 1 a 4;
  - la mitad envía también `total_amount` calculado con los precios del dataset, como un canal que quiere que la API confirme su cálculo.
- **Órdenes inválidas** que la API debe rechazar con `422`:

  | Caso | Error esperado |
  |---|---|
  | Producto que no está en el catálogo | `items[0].product_id: not_found` |
  | Cantidad `0` | `items[0].quantity: invalid_quantity` |
  | Cantidad `2.5`, que no debe truncarse | `items[0].quantity: invalid_quantity` |
  | Delivery sin dirección | `delivery_address: blank` |
  | `total_amount` menor que el real | `total_amount: total_mismatch` |
  | Restaurante inexistente | `restaurant_id: not_found` |
  | Sin productos | `items: blank` |

- **Manejo de respuestas:** cada orden se marca `ok` si recibió lo esperado (`201` las válidas, `422` las inválidas) y `!!` si no. Un error de red se informa como resultado y no detiene la simulación.
- **Cada orden lleva su propia `Idempotency-Key`**, igual que un canal real que quiere poder reintentar sin duplicar.
- **Código de salida:** `0` si todas las respuestas fueron las esperadas, `1` si hubo alguna inesperada o algún error de red. Así se puede usar en un pipeline.

## Ejemplo de salida

Con el stack levantado (`docker compose up`):

```
$ ruby script/simulate_orders.rb --count 30 --invalid-ratio 0.2 --seed 42
Sending 30 orders to http://localhost:3000 (seed 42, ~20% invalid)

ok   1. valid                                                   -> 201 NUNO-000007 pickup $37420 (NUNO)
ok   2. valid                                                   -> 201 PROV-000008 pickup $31140 (PROV)
ok   3. valid                                                   -> 201 PROV-000009 pickup $50690 (PROV)
ok   4. invalid: no products at all                             -> 422 items:blank
ok   5. invalid: a product that is not in the catalog           -> 422 items[0].product_id:not_found
ok   6. valid                                                   -> 201 NUNO-000010 delivery $82570 (NUNO)
...
ok  14. invalid: a quantity of 2.5, which must not be truncated -> 422 items[0].quantity:invalid_quantity
...
ok  26. invalid: a total_amount lower than the real one         -> 422 total_amount:total_mismatch
...
ok  30. valid                                                   -> 201 LCON-000030 delivery $14750 (LCON)

Summary
-------
Orders sent:             30
Created (201):           24
Invalid on purpose:      6 (rejected with 422: 6)
Network errors:          0
Unexpected answers:      0
Created by restaurant:   LCON=6, NUNO=11, PROV=7
Created by order type:   delivery=12, pickup=12
Total amount created:    $1146940
```

Las órdenes creadas se despachan a sus tiendas en segundo plano. Se puede revisar su estado en `GET /api/v1/orders/:id` o en lo que recibió cada tienda con `GET /simulated_stores/:code/orders`.
