# AGENTS.md — Inteligência Mínima e Diretrizes para Agentes de IA

Este documento define as regras operacionais, convenções e restrições obrigatórias para qualquer agente de IA ou automação operando no repositório **Laboratório Volt (`laboratorio_volt`)**.

---

## 1. Princípios e Postura Operacional

1. **Interlocutor Volt:** O agente opera sob a disciplina Volt. Toda comunicação com o usuário humano deve ser transparente, técnica e orientada a evidências verificadas.
2. **Regra de Ouro do Zero Atrito Externo:** **NUNCA injete manifestos do Volt (`.volt`, `Dockerfile.volt`, `docker-compose.volt.yml`, etc.) dentro dos repositórios dos projetos externos de negócio.** 
   - Toda inteligência de empacotamento e execução de projetos externos deve residir dentro de `adapters/<nome-do-projeto>/` neste repositório coordenador.
   - Pull Requests enviados para repositórios externos devem conter **exclusivamente código de negócio** solicitado pela demanda.
3. **Soberania do Workspace:** O repositório `laboratorio_volt` gerencia a orquestração do ambiente, rede, painel de controle e adaptadores. O único Pull Request de governança do ecossistema deve ser aberto neste repositório.
4. **Isolamento de Demandas:** Cada nova demanda/issue (ex: `CC-1000`) deve ser trabalhada em sua respectiva worktree isolada em `.workspace/worktrees/<ID>/<projeto>`, mantendo as fontes canônicas limpas.

---

## 2. Mapa do Ecossistema e Repositórios

| Projeto | Repositório Remoto | Branch Padrão | Localização no Workspace |
| :--- | :--- | :--- | :--- |
| **Workspace Coordenador** | `marcodotcastro/laboratorio_volt` | `main` | `/home/marcodotcastro/Projects/laboratorio_volt` |
| **Portal Agro** | `marcodotcastro/portal-agro` | `master` | `.workspace/sources/portal-agro` |
| **PMOC Pro** | `marcodotcastro/pmoc-pro` | `main` | `.workspace/sources/pmoc-pro` |

---

## 3. Gestão de Adaptadores Soberanos (`adapters/`)

Quando um novo projeto for integrado ao workspace:
1. Criar um diretório correspondente sob `adapters/<nome-do-projeto>/`.
2. Escrever o `Dockerfile` com os pacotes, runtimes e ferramentas necessários para compilar e rodar aquele projeto.
3. Escrever o `docker-compose.yml` local declarando bancos de dados e serviços auxiliares com seus respectivos *healthchecks*.
4. Configurar a montagem de volume apontando para a worktree ativa do projeto (`.workspace/worktrees/<ISSUE>/<projeto>`).

---

## 4. Fluxo de Trabalho de Demandas (Exemplo: CC-1000)

1. **Criação de Worktrees por Demanda:**
   - Criar a branch de trabalho em cada repositório envolvido.
   - Criar a worktree isolada sob `.workspace/worktrees/<ID>/<projeto>`.
2. **Inicialização da Malha de Serviços:**
   - Garantir que a rede Docker `c2s_workspace_edge` esteja ativa.
   - Subir os contêineres utilizando os adaptadores e o orquestrador `docker-compose.yml`.
   - Validar retorno HTTP com código 200 nos endpoints locais.
3. **Execução Técnica:**
   - Realizar as alterações necessárias no código da aplicação estritamente dentro da worktree do projeto.
4. **Abertura de Pull Requests:**
   - No repositório de negócio: submeter apenas os commits de código de negócio.
   - No repositório coordenador (`laboratorio_volt`): submeter alterações de orquestração, documentação e adaptadores.

---

## 5. Regras de Segurança e Higiene Operacional

1. **Proteção contra Vazamento de Credenciais:** Nunca commitar arquivos `.env`, segredos de infraestrutura, credenciais de banco ou Rails Master Key.
2. **Evidência Antes de Conclusão:** Nunca declarar uma demanda pronta sem inspecionar saídas de terminal, status de contêineres e códigos HTTP de resposta.
