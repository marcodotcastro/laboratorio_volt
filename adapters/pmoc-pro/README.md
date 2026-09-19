# Adaptador Soberano — PMOC Pro

Este adaptador encapsula a inteligência de runtime do **PMOC Pro** dentro do Workspace Laboratório Volt, sem injetar qualquer arquivo no repositório externo do projeto.

## Características do Runtime
- **Stack:** Ruby 3.2.2 / Rails 7 / PostgreSQL 16 / Redis 7
- **Infraestrutura embutida:** PostgreSQL e Redis provisionados automaticamente via Docker com *healthcheck*
- **Comando de Start:** `./bin/rails server -b 0.0.0.0 -p 3000`
- **Porta Padrão:** `3002` no host
