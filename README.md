# Laboratório Volt — Workspace Soberano

> **Sua estação de alta performance para entregar demandas complexas sem atrito, sem burocracia e sem poluir repositórios de clientes.**

---

## Por Que Este Workspace Existe?

Desenvolver em projetos corporativos, softwares legados ou ecossistemas multi-repositório quase sempre envolve atrito desnecessário:
- Máquinas emperradas configurando bancos de dados, runtimes conflitantes e variáveis de ambiente;
- Burocracia política para aprovar ferramentas de inteligência artificial ou manifestos de infraestrutura nos repositórios oficiais da empresa;
- Medo de quebrar o ambiente local ao alternar entre tarefas e branches de clientes diferentes.

O **Laboratório Volt** elimina essa dor na raiz. Ele atua como uma estação de desenvolvimento soberana onde **você só precisa falar com o Volt (`/volt`)**.

Toda a complexidade de compilação, redes virtuais, portas e bancos de dados é absorvida pelo agente. O repositório da empresa permanece 100% limpo, recebendo apenas o código de negócio validado, enquanto você trabalha com velocidade de elite e total autonomia.

---

## O Conceito dos Adaptadores Soberanos

Para blindar o código do cliente contra arquivos de ferramentas ou configurações estranhas, este workspace utiliza **Adaptadores Soberanos** (`adapters/`):

- **O Repositório do Cliente fica intocado:** Nenhum arquivo do Volt, script pessoal ou Dockerfile desconhecido é comitado no repositório externo.
- **O Adaptador resolve o runtime aqui dentro:** O Workspace Volt guarda a receita de como compilar e rodar cada aplicação (Ruby, PHP, Node, Python, bancos PostgreSQL, Redis ou SQLite).
- **Execução Desacoplada:** O código do projeto é montado via volume dentro do contêiner isolado da demanda. O cliente recebe apenas a solução da tarefa; você desfruta de um ambiente completo com painel visual no navegador.

---

## Estrutura do Workspace e Ciclo de Demandas (Orca)

O workspace é estruturado em torno do fluxo contínuo de demandas gerenciadas pelo **Orca**, garantindo que cada tarefa nasça em uma worktree totalmente isolada:

```text
laboratorio_volt/
├── adapters/                     # Inteligência de runtime de cada projeto (zero poluição externa)
│   ├── portal-agro/              # Adaptador para Rails 8 / SQLite3
│   └── pmoc-pro/                 # Adaptador para Rails 7 / PostgreSQL / Redis
│
├── .workspace/
│   ├── sources/                  # Fontes oficiais dos projetos (cópias limpas)
│   │   ├── portal-agro/
│   │   └── pmoc-pro/
│   │
│   └── worktrees/                # Ambientes isolados guiados pelo Orca por Demanda
│       ├── CC-1000/              # [DEMANDA ATIVA] Ambiente isolado da Issue 1000
│       │   ├── marketing-hub/    # Painel de controle visual (http://cc1000.localhost)
│       │   ├── portal-agro/      # Código do Portal Agro na branch da demanda
│       │   └── pmoc-pro/         # Código do PMOC Pro na branch da demanda
│       │
│       └── CC-1001/              # [PRÓXIMA DEMANDA] Próxima tarefa instanciada sem atritos
│
├── AGENTS.md                     # Diretrizes de inteligência mínima para os agentes Volt
└── README.md                     # Este manifesto de valor
```

### O Fluxo Guiado pelo Orca
1. **Nova Demanda:** O Orca sinaliza uma issue (ex: `CC-1000`).
2. **Isolamento Instantâneo:** O Volt cria a pasta da demanda sob `.workspace/worktrees/<DEMANDA>/`, conecta os adaptadores necessários e disponibiliza o painel visual no navegador.
3. **Entrega de Valor:** Você desenvolve conversando com o Volt. Ao finalizar, o Pull Request do projeto recebe apenas a melhoria de negócio, pronto para merge.
