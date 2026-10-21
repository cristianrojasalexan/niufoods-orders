# Niufoods Orders

API central para recibir, validar, persistir y despachar órdenes a los restaurantes de la franquicia, con un dashboard para revisarlas.

> 🚧 En construcción. La documentación completa (arquitectura, flujo de órdenes, instalación y ejemplos de uso) se irá agregando a medida que avance la solución.

## Documentación

- [Arquitectura, modelo de datos y flujo de una orden](docs/architecture.md)
- [API de órdenes: contrato, validaciones y errores](docs/api.md)
- [Despacho a tienda: claim, lease, reintentos y recuperación](docs/dispatch.md)
- [Tiendas simuladas: recepción, deduplicación y modos](docs/simulated_stores.md)
- [Simulación de órdenes: script, casos válidos e inválidos](docs/simulation.md)

## Stack

- Ruby 3.4 / Rails 8.1
- PostgreSQL
- Tailwind CSS + Hotwire
- Redis + Sidekiq

## Ejecución con Docker

Levanta todo (PostgreSQL, Redis, la app, el worker de Sidekiq y la recuperación de despachos) con un solo comando:

```bash
docker compose up --build
```

- La app queda en http://localhost:3000: el dashboard de órdenes en `/`, la API en `/api/v1`, las tiendas simuladas en `/simulated_stores` y Sidekiq en `/sidekiq`.
- Orden de arranque: `setup` prepara la base y carga las seeds; recién después arranca `web`, y `sidekiq` y `dispatch_recovery` esperan a que `web` responda. Así el primer inicio funciona desde cero y el worker nunca entrega órdenes a tiendas que todavía no escuchan.
- `web`, `sidekiq` y `dispatch_recovery` se reinician solos si se caen; por ejemplo, Sidekiq termina si arranca sin Redis disponible.
- Docker usa su propia base (`niufoods_orders_docker`) y su propia base de Redis (`/1`), separadas de las de la ejecución local, para que los workers de un entorno nunca tomen jobs del otro.
- Variables como `STORE_MODES` o `MAX_ATTEMPTS_PER_CYCLE` se configuran en un archivo `.env` junto a `docker-compose.yml` (ver `.env.example`).
- El primer build compila las gemas y puede tardar varios minutos; los siguientes reutilizan la caché.
- Para empezar de cero: `docker compose down -v && docker compose up --build`.

## Ejecución local, sin Docker para la app

Requiere Ruby 3.4.11. PostgreSQL y Redis pueden venir del mismo `docker-compose.yml`:

```bash
docker compose up -d --wait db redis
bin/setup --skip-server   # gemas, base de datos y seeds
bin/dev                   # servidor web, Tailwind, worker de Sidekiq y recuperación
```

`db:prepare` crea la base, corre las migraciones y, si la base es nueva, carga las seeds. Las seeds se pueden volver a correr cuando quieras con `bin/rails db:seed`: cargan el dataset de la prueba (`db/data/restaurants.json` y `db/data/products.json`) con sus IDs originales y nunca duplican registros.

Las credenciales por defecto de `config/database.yml` coinciden con el servicio `db`. Para cambiarlas, copia `.env.example` y ajusta las variables `DB_*`.

## Tests y lint

```bash
bin/ci                 # todo lo de abajo, en el mismo orden que el CI
bundle exec rspec      # suite de tests (RSpec + FactoryBot + shoulda-matchers + WebMock)
bin/rubocop            # estilo (rubocop-rails-omakase)
bin/brakeman           # análisis estático de seguridad
bin/bundler-audit      # vulnerabilidades conocidas en las gemas
```

Los tests bloquean cualquier llamada HTTP real con WebMock: toda comunicación con las tiendas se stubbea.
