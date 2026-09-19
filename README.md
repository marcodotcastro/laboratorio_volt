# Laboratório Volt — Workspace Coordenador Soberano

O **Laboratório Volt** é o ambiente unificado de orquestração inteligente e desenvolvimento multi-repositório projetado para execução técnica guiada por demandas sob a metodologia Volt.

---

## 1. Visão Geral e Princípio Soberano de Zero Atrito

Este repositório atua como um **Workspace Coordenador Soberano e Furtivo**. Ele foi desenhado para eliminar por completo o atrito de adoção em empresas, consultorias e equipes de engenharia tradicionais.

### O Dilema do Desenvolvedor Corporativo
No mundo real, projetos corporativos (seja um legado em PHP, uma API Rails ou um microsserviço Node) possuem barreiras burocráticas:
- Tech leads ou equipes de segurança que barram Pull Requests contendo arquivos desconhecidos de inteligência artificial ou infraestruturas não homologadas.
- Discussões desnecessárias sobre por que determinados manifests (`.volt`, Dockerfiles customizados) foram incluídos na raiz do projeto da empresa.

### A Solução Volt: Repositórios Externos Intocados
No Laboratório Volt, **o repositório externo da empresa nunca recebe arquivos do Volt**:
- **Repositório da Empresa:** Permanece 100% puro. Quando uma demanda é finalizada, o Pull Request enviado para o cliente ou para a empresa contém **estritamente o código de negócio** que precisava ser alterado (o bugfix, a nova rota, a tela ajustada).
- **Workspace Soberano Volt:** Centraliza privadamente toda a "cozinha técnica" de alta performance: os adaptadores de contêineres, orquestração de rede local, worktrees efêmeras por issue e inteligência de agentes.

---

## 2. A Experiência "Fale Apenas com o Volt"

A premissa do workspace é oferecer abstração cognitiva total para quem desenvolve:

> **Você só precisa falar com o Volt (`/volt`).**

Não é necessário memorizar:
- Comandos específicos de bancos de dados diferentes (PostgreSQL, SQLite, MySQL, Redis);
- Diferenças de versões de runtimes (Ruby 3.2 vs Ruby 3.3, PHP 7 vs PHP 8, Node, Python);
- Variáveis de ambiente obscuras, migrações manuais ou flags de compilação de assets;
- Como configurar proxies reversos, certificados e DNS local para que os projetos se comuniquem.

Ao receber uma demanda (como a issue `CC-1000`), o Volt:
1. Cria as **worktrees Git isoladas** para os projetos sob `.workspace/worktrees/CC-1000/`;
2. Utiliza os adaptadores contidos em `adapters/` dentro deste workspace para construir e subir contêineres otimizados;
3. Monta o código-fonte da worktree via volume nos contêineres em tempo real;
4. Conecta tudo à malha de rede unificada com roteamento dinâmico;
5. Disponibiliza o **Painel de Controle Volt** no navegador para inspeção humana imediata.

---

## 3. Arquitetura de Adaptadores Soberanos (`adapters/`)

Para que cada projeto funcione de forma isolada sem poluir o repositório original, este workspace mantém o diretório canônico `adapters/`:

```text
laboratorio_volt/
├── adapters/
│   ├── portal-agro/
│   │   ├── Dockerfile            # Imagem otimizada Ruby 3.3 / Rails 8
│   │   ├── docker-compose.yml    # Orquestração isolada com SQLite3 WAL
│   │   └── README.md             # Guia técnico do runtime
│   └── pmoc-pro/
│       ├── Dockerfile            # Imagem Ruby 3.2 / Rails 7
│       ├── docker-compose.yml    # Orquestração com PostgreSQL 16 + Redis 7
│       └── README.md             # Guia técnico do runtime
```

### Como o Adaptador Opera
- O `Dockerfile` do adaptador sabe exatamente como compilar a stack daquele projeto específico.
- O `docker-compose.yml` do adaptador sobe os bancos de dados auxiliares necessários com verificações de saúde (*healthchecks*).
- O código-fonte do projeto alvo é montado via volume a partir da worktree ativa (`.workspace/worktrees/<ISSUE>/<projeto>`).
- Dessa forma, o projeto roda com fidelidade total e isolamento completo sem que uma única linha de configuração do Volt precise ser comitada no repositório externo.

---

## 4. Topologia e Serviços do Laboratório

### Projetos Conectados Atualmente
| Componente | Repositório Oficial | Stack | Banco de Dados | Localização do Adaptador |
| :--- | :--- | :--- | :--- | :--- |
| **Laboratório Volt** | `marcodotcastro/laboratorio_volt` | Nginx / Shell / Docker | N/A | Workspace Coordenador |
| **Portal Agro** | `marcodotcastro/portal-agro` | Ruby 3.3 / Rails 8 | SQLite3 (WAL) | `adapters/portal-agro/` |
| **PMOC Pro** | `marcodotcastro/pmoc-pro` | Ruby 3.2 / Rails 7 | PostgreSQL 16 + Redis 7 | `adapters/pmoc-pro/` |

### Acesso no Navegador (Demanda Ativa CC-1000)
- **Painel de Controle Volt:** [http://cc1000.localhost/](http://cc1000.localhost/)
- **Portal Agro:** [http://portal-agro.cc1000.localhost/](http://portal-agro.cc1000.localhost/) *(ou porta 3001)*
- **PMOC Pro:** [http://pmoc-pro.cc1000.localhost/](http://pmoc-pro.cc1000.localhost/) *(ou porta 3002)*

---

## 5. Estrutura de Diretórios do Workspace

```text
laboratorio_volt/
├── adapters/                     # Adaptadores soberanos de cada projeto externo
│   ├── portal-agro/
│   └── pmoc-pro/
├── .workspace/
│   ├── sources/                  # Clones dos repositórios remotos canônicos
│   │   ├── portal-agro/
│   │   └── pmoc-pro/
│   └── worktrees/                # Ambientes efêmeros e isolados por issue
│       └── CC-1000/
│           ├── marketing-hub/    # Painel de controle web
│           ├── portal-agro/      # Worktree do Portal Agro
│           └── pmoc-pro/         # Worktree do PMOC Pro
├── bin/                          # Utilitários de linha de comando
├── docker-compose.yml            # Orquestrador da demanda ativa
├── scripts/                      # Scripts de automação e ciclo de vida
├── AGENTS.md                     # Guia de inteligência mínima para agentes de IA
└── README.md                     # Esta documentação soberana
```

---

## 6. Operação e Ciclo de Vida

```bash
# Inspecionar status dos serviços da demanda ativa
docker compose ps

# Subir a malha completa da demanda CC-1000
docker compose up -d

# Visualizar logs em tempo real
docker compose logs -f

# Encerrar os serviços liberando portas
docker compose down
```
