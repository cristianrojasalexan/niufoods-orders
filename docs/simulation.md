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

- **Manejo de respuestas:** cada orden se marca `ok` si recibió lo esperado (`201` las válidas, `422` las inválidas) y `!!` si no. Un error de red se informa como resultado de esa orden y la simulación sigue con las demás. Esto incluye conexión rechazada o cortada, timeout, DNS, un certificado TLS inválido o vencido y una respuesta HTTP mal formada.
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

## Escenarios de demo del despacho

`script/demo_scenarios.rb` muestra el despacho funcionando de punta a punta en cuatro escenarios controlados. En cada uno configura el modo de una tienda simulada, crea una orden para esa tienda y consulta `GET /api/v1/orders/:id` hasta que el despacho llega a un estado final (`dispatched` o `failed`; `pending` entre reintentos no es final).

```bash
ruby script/demo_scenarios.rb                              # tienda PROV, hasta 120 s por escenario
ruby script/demo_scenarios.rb --store LCON --timeout 200   # otra tienda, más tiempo
```

| Escenario | La tienda… | Resultado esperado | La tienda recibió la orden |
|---|---|---|---|
| `ok` | acepta la orden | `dispatched` en 1 intento | sí (1 solicitud) |
| `flaky:2` | responde `503` dos veces y después la acepta | `dispatched` en 3 intentos | sí (3 solicitudes) |
| `reject` | la rechaza con `422` (error permanente) | `failed` en 1 intento | no (1 solicitud) |
| `down` | responde siempre `503` | `failed` en 5 intentos | no (5 solicitudes) |

| Opción | Default | Uso |
|---|---|---|
| `--url` | `http://localhost:3000` | URL base de la API y las tiendas. También se puede definir con `SIMULATION_URL`. |
| `--store` | `PROV` | Tienda del dataset que usan los escenarios. |
| `--timeout` | `120` | Segundos máximos de espera por escenario. |
| `--max-attempts` | `5` | El `MAX_ATTEMPTS_PER_CYCLE` de la API, que define los intentos esperados del escenario `down`. |

**Qué verifica:** para cada escenario compara lo esperado con lo obtenido en tres cosas:
- el estado final del despacho;
- los intentos del ciclo;
- lo que registró la tienda (`GET /simulated_stores/:code/orders`): si la recibió y cuántas solicitudes le llegaron.

Así se comprueba también que los reintentos no duplican la orden en la tienda. El código de salida es `0` si los cuatro escenarios pasan y `1` si alguno no.

**Deja la tienda como estaba:** guarda el modo original de la tienda y lo restaura en un `ensure`, aunque un escenario falle, la API deje de responder o se interrumpa con Ctrl-C.

**Requisitos y tiempos:** necesita la API, Sidekiq y las tiendas corriendo (`docker compose up` o `bin/dev`). Los dos usan `DISPATCH_RETRY_BASE_SECONDS=2`, así que el escenario `down` espera 2 + 4 + 8 + 16 = 30 s entre intentos, más lo que tarda Sidekiq en tomar cada reintento programado. La demo completa toma alrededor de un minuto. Con la base por defecto de 10 s, `down` espera 150 s: en ese caso hay que usar `--timeout 200`.

Mientras corre, la tienda elegida responde según el modo de cada escenario a **todas** sus órdenes. Conviene no correr la simulación contra esa tienda al mismo tiempo.

### Ejemplo de salida

```
$ ruby script/demo_scenarios.rb
Running 4 dispatch scenarios against http://localhost:3000 (timeout 120s each)
Store PROV is in mode ok; it will be restored at the end.

1. ok       the store accepts the order            PROV-000070 .. -> dispatched, 1 attempt (2.7s) ok
2. flaky:2  503 twice, then the store accepts it   PROV-000071 .............. -> dispatched, 3 attempts (15.1s) ok
3. reject   the store rejects the order with 422   PROV-000072 . -> failed, 1 attempt (1.2s) ok
4. down     the store always answers 503           PROV-000073 ....................................... -> failed, 5 attempts (40.6s) ok

Store mode  Expected                Got                     Store received    Result
----------  ----------------------  ----------------------  ----------------  ------
ok          dispatched, 1 attempt   dispatched, 1 attempt   yes (1 request)   PASS
flaky:2     dispatched, 3 attempts  dispatched, 3 attempts  yes (3 requests)  PASS
reject      failed, 1 attempt       failed, 1 attempt       no (1 request)    PASS
down        failed, 5 attempts      failed, 5 attempts      no (5 requests)   PASS

4 of 4 scenarios passed.
Store PROV restored to mode ok.
```

Las órdenes de la demo quedan en el dashboard, con sus intentos agrupados por ciclo en el detalle. Por ejemplo, la orden del escenario `reject` se puede reintentar desde ahí después de volver la tienda a `ok`.
