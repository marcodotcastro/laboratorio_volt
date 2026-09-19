# AGENTS.md — Inteligência Mínima e Diretrizes para Agentes de IA

Este documento define as regras operacionais, convenções e restrições obrigatórias para qualquer agente de IA ou automação operando no repositório **Laboratório Volt (`laboratorio_volt`)**.

---

## 1. Princípios e Postura

1. **Interlocutor Volt:** O agente opera sob a disciplina Volt. Toda comunicação com o usuário humano deve ser transparente, técnica e orientada a evidências verificadas.
2. **Soberania do Workspace:** O repositório `laboratorio_volt` gerencia orquestração de ambiente, rede, painel de controle e esteiras. Não misture código de negócio de aplicações nos commits deste repositório.
3. **Isolamento de Projetos:** Os projetos de negócio (`portal-agro`, `pmoc-pro`, etc.) vivem em repositórios próprios. Toda e qualquer alteração de código ou funcionalidade deve ser commitada e enviada via branch correspondente dentro da worktree do respectivo projeto.
4. **Camada de Abstração Volt:** Cada projeto deve possuir `Dockerfile.volt` e `docker-compose.volt.yml` funcionais para que possa ser executado tanto isoladamente quanto dentro da malha orquestrada pelo Volt.

---

## 2. Mapa do Ecossistema e Repositórios

| Projeto | Repositório Remoto | Branch Padrão | Localização no Workspace |
| :--- | :--- | :--- | :--- |
| **Workspace Coordenador** | `marcodotcastro/laboratorio_volt` | `main` | `/home/marcodotcastro/Projects/laboratorio_volt` |
| **Portal Agro** | `marcodotcastro/portal-agro` | `master` | `.workspace/sources/portal-agro` |
| **PMOC Pro** | `marcodotcastro/pmoc-pro` | `main` | `.workspace/sources/pmoc-pro` |

---

## 3. Fluxo Canônico para Demandas / Issues (Exemplo: CC-1000)

Quando uma nova demanda for iniciada:

1. **Criação de Worktrees por Demanda:**
   - Criar branch `feat/<id>-<slug>` em cada repositório envolvido.
   - Instanciar a worktree sob `.workspace/worktrees/<ID>/<projeto>`.
   - Garantir que o repositório principal nunca seja poluído com trabalho em andamento desorganizado.
2. **Configuração da Malha de Execução:**
   - Montar a rede Docker `c2s_workspace_edge` caso ainda não exista.
   - Atualizar o `docker-compose.yml` da demanda referenciando os volumes e caminhos da worktree correspondente.
   - Subir os contêineres via `docker compose up -d` e verificar saúde via `docker compose ps` e `curl -I`.
3. **Execução Técnica com TDD e Semantic Commits:**
   - Realizar commits atômicos com mensagens semânticas no formato Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`).
4. **Entrega Semântica e Pull Requests:**
   - Subir as branches para o respectivo repositório remoto no GitHub (`git push -u <remote> <branch>`).
   - Abrir Pull Requests conectados usando a CLI `gh`:
     ```bash
     gh pr create --repo <owner>/<repo> --base <base-branch> --head <feature-branch> --title "..." --body "..."
     ```
   - Apresentar os links de validação ao usuário.

---

## 4. Como os Projetos Iniciam e Operam

### Portal Agro
- **Inicialização Isolada:** `docker compose -f docker-compose.volt.yml up -d`
- **Porta Host Padrão:** `3001` (porta interna: `3000`)
- **Dependências:** Nenhuma externa; utiliza SQLite3 com WAL mode em `storage/`.
- **Preparo de Banco:** `bin/rails db:prepare`

### PMOC Pro
- **Inicialização Isolada:** `docker compose -f docker-compose.volt.yml up -d`
- **Porta Host Padrão:** `3002` (porta interna: `3000`)
- **Dependências:** PostgreSQL 16 (porta interna `5432`) e Redis 7 (porta interna `6379`).
- **Preparo de Banco:** Inicializado automaticamente pelo entrypoint do container ou `bin/rails db:prepare`.

---

## 5. Regras de Segurança e Higiene Operacional

1. **Proteção contra Vazamento de Credenciais:** Nunca commitar arquivos `.env`, chaves de API, credenciais do Supabase, AWS ou Rails Master Key. Utilizar variáveis de ambiente ou placeholders `dummy_...` para compilação local de assets.
2. **Evidência Antes de Conclusão:** Nunca declarar um serviço funcional ou um teste concluído sem antes inspecionar o código de saída (`exit code 0`), status do container (`Up (healthy)`) e retorno HTTP (`200 OK`).
