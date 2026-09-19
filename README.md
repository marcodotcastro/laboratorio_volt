# Laboratório Volt — Workspace Coordenador Soberano

O **Laboratório Volt** é o ambiente unificado de orquestração inteligente e desenvolvimento multi-repositório projetado para execução técnica guiada por demandas sob a metodologia Volt.

---

## 1. Visão Geral e Princípio Soberano

Este repositório atua como **Workspace Coordenador Soberano**. Ele centraliza a inteligência de orquestração, automação de esteiras e governança de tarefas sem acoplar o código-fonte das aplicações de negócio.

### Fronteira de Responsabilidade
- **Sob controle soberano deste repositório:** Apenas este laboratório/workspace (`laboratorio_volt`), seus manifestos de orquestração de rede, scripts de automação, documentação do ecossistema e hub central de comando.
- **Fontes externas e projetos integrados:** Aplicações de negócio (como `portal-agro` e `pmoc-pro`) são mantidas como módulos de código isolados sob `.workspace/sources/`. Cada uma possui seu próprio repositório no GitHub, seu próprio histórico Git, suas dependências e seu ciclo de vida independente.

---

## 2. A Experiência "Fale Apenas com o Volt"

O diferencial central deste workspace é a abstração cognitiva total para a pessoa desenvolvedora ou operadora:

> **Você só precisa falar com o Volt (`/volt`).**

Não é necessário memorizar:
- Comandos específicos de bancos de dados diferentes (PostgreSQL, SQLite, Redis);
- Diferenças de versões de runtimes (Ruby 3.2 vs Ruby 3.3, Bundler, Node, Yarn);
- Variáveis de ambiente obscuras ou flags de compilação de assets;
- Como levantar proxies reversos e DNS local para que os projetos se comuniquem.

Ao receber uma demanda (por exemplo, `CC-1000`), o Volt:
1. Provisiona as **worktrees Git isoladas** para cada projeto envolvido sob `.workspace/worktrees/CC-1000/`;
2. Instancia as dependências e serviços usando a camada de containerização padrão do Volt de cada projeto;
3. Conecta todos os contêineres à rede unificada (`c2s_workspace_edge`) com roteamento Traefik;
4. Disponibiliza o **Painel de Controle Volt** com acesso direto às aplicações no navegador;
5. Gerencia branches correspondentes e abre os **Pull Requests** sincronizados em cada repositório.

---

## 3. Camada de Abstração e Isolamento dos Projetos

Um princípio imutável da arquitetura Volt é que **cada projeto deve ser capaz de funcionar 100% isolado**.

Para garantir isso, o Volt não insere regras rígidas de execução no workspace coordenador. Em vez disso, cada projeto hospeda em seu próprio repositório os manifestos canônicos de abstração Volt:

- **`Dockerfile.volt`**: Manifesto de empacotamento otimizado que sabe exatamente como compilar e preparar a stack daquele projeto específico.
- **`docker-compose.volt.yml`**: Orquestrador local que sabe quais bancos e serviços auxiliares o projeto exige para rodar de forma totalmente autônoma.
- **`.volt/`**: Metadados, documentação de inicialização e registros semânticos de demandas.

Dessa forma, o coordenador apenas invoca e conecta essas interfaces padronizadas, mantendo a arquitetura desacoplada, limpa e reutilizável para qualquer tecnologia.

---

## 4. Projetos do Laboratório e Topologia de Serviços

### Mapa dos Componentes Atuais
| Componente | Repositório Oficial | Stack | Banco de Dados | Papel no Ecossistema |
| :--- | :--- | :--- | :--- | :--- |
| **Laboratório Volt** | `marcodotcastro/laboratorio_volt` | Shell / Docker / Nginx | N/A | Workspace Coordenador e Painel de Controle |
| **Portal Agro** | `marcodotcastro/portal-agro` | Ruby 3.3 / Rails 8 | SQLite3 (WAL) | Aplicação web e portal de agronegócio |
| **PMOC Pro** | `marcodotcastro/pmoc-pro` | Ruby 3.2 / Rails 7 | PostgreSQL 16 + Redis 7 | Gestão de manutenção e contratos técnicos |

### Roteamento e Acesso no Navegador (Demanda CC-1000)
- **Painel de Controle Volt:** [http://cc1000.localhost/](http://cc1000.localhost/)
- **Portal Agro:** [http://portal-agro.cc1000.localhost/](http://portal-agro.cc1000.localhost/)
- **PMOC Pro:** [http://pmoc-pro.cc1000.localhost/](http://pmoc-pro.cc1000.localhost/)

---

## 5. Estrutura do Workspace

```text
laboratorio_volt/
├── .workspace/
│   ├── sources/                  # Clones dos repositórios remotos canônicos
│   │   ├── portal-agro/
│   │   └── pmoc-pro/
│   └── worktrees/                # Ambientes de trabalho efêmeros isolados por issue
│       └── CC-1000/
│           ├── marketing-hub/    # Painel estático servido via Nginx
│           ├── portal-agro/      # Worktree com branch feat/cc1000-improvement
│           └── pmoc-pro/         # Worktree com branch feat/cc1000-improvement
├── bin/                          # Utilitários de linha de comando
├── docker-compose.yml            # Compose orquestrador da demanda ativa
├── scripts/                      # Scripts de ciclo de vida (setup, teardown, proxy)
├── AGENTS.md                     # Guia de inteligência mínima para agentes de IA
└── README.md                     # Esta documentação soberana
```

---

## 6. Ciclo de Vida e Operação Manual

Caso deseje operar o ambiente sem o assistente interativo:

```bash
# Verificar status dos contêineres da demanda
docker compose ps

# Subir a malha completa da demanda CC-1000
docker compose up -d

# Visualizar logs consolidados
docker compose logs -f

# Derrubar a malha da demanda preservando volumes
docker compose down
```
