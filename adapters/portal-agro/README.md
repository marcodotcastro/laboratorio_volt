# Adaptador Soberano — Portal Agro

Este adaptador encapsula a inteligência de runtime do **Portal Agro** dentro do Workspace Laboratório Volt, sem injetar qualquer arquivo no repositório externo do projeto.

## Características do Runtime
- **Stack:** Ruby 3.3.6 / Rails 8
- **Persistência:** SQLite3 em modo WAL montado via volume em `/rails/storage`
- **Comando de Start:** `./bin/rails server -b 0.0.0.0 -p 3000`
- **Porta Padrão:** `3001` no host
