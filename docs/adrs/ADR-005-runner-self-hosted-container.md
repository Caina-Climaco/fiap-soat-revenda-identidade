# ADR-005: Runner self-hosted em container Linux, um por repositório

**Status:** Aceito
**Data:** 2026-10-04

## Contexto

O enunciado exige que implantações e alterações passem por CI/CD e Pull Requests. O cluster kind roda só no PC do autor ([ADR-003](ADR-003-plataforma-kind-compartilhada.md)) e um runner hospedado do GitHub não o alcança. O CD precisa, portanto, de um runner self-hosted no PC.

Na versão anterior, o repositório da API já usava um runner self-hosted em container. A tentativa inicial com o runner **nativo para Windows** falhou: o **Smart App Control** do Windows 11 bloqueou as DLLs do runner ("Uma política de Controle de Aplicativo bloqueou este arquivo", em `Runner.Common.dll`). Desligar o Smart App Control foi descartado.

Com a identidade em repositório próprio, este repositório também precisa de um CD. Em contas pessoais do GitHub (não organizações), um runner self-hosted é registrado em **um** repositório.

## Decisão

- O CI (`ci.yml`) roda no runner hospedado do GitHub (`ubuntu-latest`), sem segredos e sem acesso ao cluster.
- O CD (`cd.yml`) roda num runner self-hosted em **container Linux no Docker Desktop**, com as labels `self-hosted`, `Linux` e `kind-local`.
- **Um runner por repositório**. O deste é o container `revenda-runner-identidade`, com o volume `revenda-runner-identidade-persist` e o nome `<computador>-kind-identidade`, registrado só em `Caina-Climaco/fiap-soat-revenda-identidade`. A API tem o seu próprio container e registro.
- A imagem é construída de `infra/runner/Dockerfile`: base oficial `ghcr.io/actions/actions-runner` (2.337.0) com kind v0.33.0, kubectl v1.34.12 e Terraform 1.16.4, todos com checksum (e, no Terraform, assinatura GPG da HashiCorp) conferidos, mais Python 3 para os testes.
- O container fica na rede docker `kind` (alcança o cluster por `revenda-control-plane`), usa o Docker do host pelo socket montado e grava o state em `/revenda-state`, bind mount de `%USERPROFILE%\.revenda` ([ADR-002](ADR-002-segredos-terraform-state-externo.md)).
- O runner roda como o usuário `runner` (UID 1001), não root; o entrypoint dá acesso ao socket pelo grupo dele. O token de registro é obtido com `gh api`, passado só por variável de ambiente, usado uma vez e removido antes de o runner aceitar jobs; o registro fica no volume e é reaproveitado.
- O CD só dispara em `push` na `main` e em `workflow_dispatch` restrito a commits da `main`; nenhum workflow self-hosted reage a `pull_request` ([docs/ci-cd.md, seção 5](../ci-cd.md#5-por-que-o-runner-self-hosted-não-reage-a-pull_request)).
- Instalação e remoção: `scripts\windows\03-instalar-runner.ps1` (`-Remover`).

## Consequências

### Positivas

- O CD alcança o cluster real, com Linux nativo e fora do alcance do Smart App Control.
- Cada repositório controla o próprio runner: um não executa jobs do outro, e um runner fora do ar não para o CD do outro serviço.
- O container reinicia sozinho (`--restart unless-stopped`) e só enxerga do Windows o diretório do state.
- O Dockerfile é praticamente igual ao da API, e o job `infra` do CI roda hadolint e shellcheck nele.

### Negativas

- O socket do Docker montado equivale a privilégio de administrador sobre o Docker do PC, inclusive sobre o cluster e o namespace da API.
- O CD depende do PC ligado; com ele desligado, o deploy fica na fila.
- Dois containers de runner consomem mais memória que um.
- O repositório é público, e a documentação do GitHub desaconselha runners self-hosted em repositórios públicos.
- Cada repositório constrói a imagem com nome próprio (`revenda-runner-identidade:<versão>` aqui, `revenda-runner:<versão>` na API), então um Dockerfile pode evoluir sem sobrescrever a imagem do outro runner.

### Mitigações

- O runner só executa código revisado e mergeado: CD restrito à `main`, CI de PR só no runner hospedado, aprovação obrigatória para workflows de forks e proteção da `main` valendo para administradores.
- O job registra o resultado no job summary; o rollback é um `workflow_dispatch` com `ref` anterior.
- Mudanças no Dockerfile devem ser replicadas no repositório da API para manter a imagem igual.

## Alternativas consideradas

| Alternativa | Prós | Contras |
|---|---|---|
| **Runner em container Linux, um por repositório** (escolhida) | Funciona com o Smart App Control; isolamento entre repositórios | Socket do Docker; dois containers |
| Runner nativo no Windows | Sem Docker no meio | Bloqueado pelo Smart App Control |
| Um único runner para os dois repositórios | Um container só | Em conta pessoal, o runner é registrado num único repositório; exigiria migrar para uma organização |
| Desligar o Smart App Control | Runner nativo funcionaria | Reduz a proteção do PC do autor só para acomodar uma ferramenta |
| Tudo no runner hospedado, com o cluster exposto por túnel | Sem runner local | Expõe o plano de controle do Kubernetes na internet |
| kind dentro do runner hospedado | Nada local | O ambiente morre no fim do job: valida, mas não implanta |
