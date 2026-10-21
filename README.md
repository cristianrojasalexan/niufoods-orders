# Niufoods Orders

API central para recibir, validar, persistir y despachar órdenes a los restaurantes de la franquicia, con un dashboard para revisarlas.

> 🚧 En construcción. La documentación completa (arquitectura, flujo de órdenes, instalación y ejemplos de uso) se irá agregando a medida que avance la solución.

## Documentación

- [Arquitectura, modelo de datos y flujo de una orden](docs/architecture.md)
- [API de órdenes: contrato, validaciones y errores](docs/api.md)

## Stack

- Ruby 3.4 / Rails 8.1
- PostgreSQL
- Tailwind CSS + Hotwire
- Redis

## Servicios de infraestructura

PostgreSQL 16 y Redis 7 se levantan con Docker Compose:

```bash
docker compose up -d --wait
bin/rails db:prepare
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
