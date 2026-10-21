# Niufoods Orders

API central para recibir, validar, persistir y despachar órdenes a los restaurantes de la franquicia, con un dashboard para revisarlas.

> 🚧 En construcción. La documentación completa (arquitectura, flujo de órdenes, instalación y ejemplos de uso) se irá agregando a medida que avance la solución.

## Documentación

- [Arquitectura, modelo de datos y flujo de una orden](docs/architecture.md)

## Stack

- Ruby 3.2 / Rails 8.0
- PostgreSQL
- Tailwind CSS + Hotwire
- Redis

## Servicios de infraestructura

PostgreSQL 16 y Redis 7 se levantan con Docker Compose:

```bash
docker compose up -d --wait
bin/rails db:prepare
```

Las credenciales por defecto de `config/database.yml` coinciden con el servicio `db`. Para cambiarlas, copia `.env.example` y ajusta las variables `DB_*`.

## Tests y lint

```bash
bundle exec rspec      # suite de tests (RSpec + FactoryBot + shoulda-matchers + WebMock)
bundle exec rubocop    # estilo (rubocop-rails-omakase)
bin/brakeman           # análisis estático de seguridad
```

Los tests bloquean cualquier llamada HTTP real con WebMock: toda comunicación con las tiendas se stubbea.
