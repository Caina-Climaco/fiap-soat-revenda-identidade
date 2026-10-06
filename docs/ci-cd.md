# CI/CD e Pull Requests

Toda mudança neste repositório, seja no realm, no Terraform, nos testes, nos scripts ou na documentação, entra por Pull Request, passa pelo CI e, depois do merge, é implantada pelo CD. Este documento descreve os dois pipelines, o runner self-hosted, a proteção da `main` e o fluxo de PR.

| Pipeline | Arquivo | Onde roda | Quando |
|---|---|---|---|
| CI | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | Runner hospedado do GitHub (`ubuntu-latest`) | Todo PR para a `main` e todo push na `main` |
| CD | [`.github/workflows/cd.yml`](../.github/workflows/cd.yml) | Runner self-hosted deste repositório (container no PC do autor) | Push na `main` (PR mergeado) e disparo manual |

Os pipelines da API ficam no repositório dela e são independentes destes: cada repositório tem o seu CI, o seu CD e o seu runner.

## 1. CI

O CI roda sem segredos do repositório e sem acesso ao cluster. Ele usa `permissions: contents: read`, faz checkout sem persistir credenciais e, num mesmo PR, cancela a execução anterior quando chega um commit novo. Não há `paths-ignore`: os checks obrigatórios precisam rodar em todo PR, inclusive nos que só mexem em documentação.

| Job | Obrigatório | O que garante |
|---|---|---|
| `qualidade` | sim | **Contrato do realm**: o `realm-revenda.json` é JSON válido e, via `jq`, o realm se chama `revenda`; o autocadastro e a proteção contra força bruta estão ligados; os papéis `cliente` e `gestor` e os clients `revenda-api`, `revenda-swagger`, `revenda-e2e` e `revenda-e2e-admin` existem; o `revenda-e2e` tem password grant; `revenda-swagger` e `revenda-e2e` têm `basic` e `roles` como escopos padrão e **não** têm `profile` nem `email` (minimização LGPD); o segredo do `revenda-e2e-admin` e a senha do `gestor.loja` vêm só dos placeholders; a conta de serviço do `revenda-e2e-admin` tem exatamente `manage-users`, `query-users` e `view-users`. **Testes**: `ruff check` e `ruff format --check` em `tests/`. **Segredos**: Trivy (`scanner: secret`) no repositório inteiro |
| `realm` | sim | Gera um `.env` com segredos aleatórios (mascarados no log), sobe Keycloak e PostgreSQL reais com `docker compose up -d --wait` e roda `pytest tests -m realm`: discovery e JWKS, token do gestor, cadastro de cliente, validação do perfil, formulário de autocadastro e privilégio mínimo do client técnico. Em falha, mostra o log do Keycloak; no fim, sempre `docker compose down -v` |
| `infra` | sim | `terraform fmt -check -recursive`, `terraform init -backend=false` e `terraform validate` em `infra/terraform`; `infra/kind/cluster.yaml` com `kind: Cluster`, `name: revenda`, os cinco mapeamentos de porta da plataforma (30080→8080, 30180→8180, 30432→15432, 30300→3000, 30900→9090) e a imagem do nó fixada por digest; shellcheck no `infra/runner/entrypoint.sh` e hadolint (binário com SHA-256 conferido) no `infra/runner/Dockerfile` |
| `titulo-pr` | não | Só em PR: o título segue Conventional Commits (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `build`, `perf`, `style`, `revert`, com escopo opcional). O título vira a mensagem do commit na `main` |

Os nomes dos jobs `qualidade`, `realm` e `infra` são os *required status checks* da `main`; renomeá-los exige mudar a proteção da branch.

**Dependabot** ([`.github/dependabot.yml`](../.github/dependabot.yml)) abre PRs semanais (segunda-feira) para as GitHub Actions, as dependências dos testes (`tests/requirements.txt`) e as imagens do `docker-compose.yml`. Esses PRs passam pelo mesmo CI. Todas as `uses:` do `ci.yml` e do `cd.yml` são fixadas pelo SHA completo do commit, com a versão em comentário (`# vX.Y.Z`), e é o Dependabot (`package-ecosystem: github-actions`) que atualiza SHA e comentário juntos; uma tag móvel como `@v7` nunca é usada, porque pode ser reapontada por quem controla o repositório da action.

## 2. CD

O CD implanta o serviço de identidade no cluster kind `revenda`, namespace `identidade`.

### 2.1 Gatilhos

- `push` na `main`, ou seja, um PR mergeado;
- `workflow_dispatch`, com um input opcional `ref` (SHA, branch ou tag). Vazio implanta o commit atual da `main`.

No disparo manual, o primeiro passo depois do checkout confere que o commit pertence ao histórico da `main` (`git merge-base --is-ancestor`) e recusa qualquer outro. Assim, só código que passou por PR e CI chega ao runner.

### 2.2 Passos

| # | Passo | Detalhes |
|---|---|---|
| 1 | Checkout | Do `ref` informado ou do commit do push, com histórico completo |
| 2 | Valida o commit (só `workflow_dispatch`) | Recusa commits fora da `main` |
| 3 | Contexto | Confere que `/revenda-state` existe e é gravável, define `KUBECONFIG` e confere as ferramentas (`docker`, `kind`, `kubectl`, `terraform`, `python3`, `curl`, `base64`) |
| 4 | Cluster kind | Se `kind get clusters` não lista `revenda`, cria com `kind create cluster --config infra/kind/cluster.yaml --wait 120s`. Depois, `kind export kubeconfig --internal` (servidor `https://revenda-control-plane:6443`, alcançável pela rede docker `kind`) |
| 5 | Terraform | `terraform init -reconfigure -backend-config=path=/revenda-state/identidade.tfstate` e `terraform apply -auto-approve`: namespace, Secrets, `keycloak-db`, Keycloak, NetworkPolicy e Job `keycloak-reconciliar` |
| 6 | Aguarda o realm | Até 300 s por uma resposta 2xx de `http://revenda-control-plane:30180/realms/revenda/.well-known/openid-configuration` |
| 7 | Testes do realm | Lê `GESTOR_PASSWORD` e `E2E_ADMIN_CLIENT_SECRET` dos Secrets (mascarados), cria um virtualenv e roda `pytest tests -m realm` contra o NodePort, gerando um relatório JUnit |
| 8 | Diagnóstico (em falha) | Pods, jobs, services, eventos, log do Keycloak e do Job de reconciliação |
| 9 | Resumo (sempre) | Tabela no job summary: commit, evento, réplicas prontas do Keycloak, resultado e contagem dos testes, URL e issuer publicados |

O job usa o environment `local` (criado pelo script 02), `permissions: contents: read` e timeout de 45 minutos.

### 2.3 Runner self-hosted em container

O CD precisa alcançar o cluster kind, que só existe no PC do autor. Por isso ele roda num runner self-hosted, e esse runner é um **container Linux** no Docker Desktop, porque o Smart App Control do Windows 11 bloqueia as DLLs do runner nativo ([ADR-005](adrs/ADR-005-runner-self-hosted-container.md)).

| Item | Valor |
|---|---|
| Imagem | `revenda-runner-identidade:<versão do runner>`, construída de [`infra/runner/Dockerfile`](../infra/runner/Dockerfile): base oficial `ghcr.io/actions/actions-runner` com kind, kubectl e Terraform de versões fixas (checksums e assinatura GPG da HashiCorp conferidos) e Python 3 |
| Container | `revenda-runner-identidade`, `--restart unless-stopped`, na rede docker `kind` |
| Nome no GitHub | `<computador>-kind-identidade`, registrado **só neste repositório** |
| Labels | `self-hosted`, `Linux`, `X64` (automáticas) e `kind-local`; o `cd.yml` pede `[self-hosted, Linux, kind-local]` |
| Docker do host | Socket `/var/run/docker.sock` montado; o entrypoint coloca o usuário `runner` (UID 1001, não root) no grupo do socket |
| Volume | `revenda-runner-identidade-persist` em `/home/runner/persist`: registro do runner e `TF_DATA_DIR` (`terraform-data-identidade`) |
| State | Bind mount de `%USERPROFILE%\.revenda` em `/revenda-state` |
| Instalação | `scripts\windows\03-instalar-runner.ps1` (depois do cluster existir); `-Remover` desregistra e remove container e volume |

O token de registro é obtido com `gh api`, passado só por variável de ambiente, usado uma vez e removido do ambiente antes de o runner começar a aceitar jobs.

A API tem o seu próprio runner, em outro container e registrado no repositório dela. Um runner nunca executa jobs do outro repositório.

### 2.4 State do Terraform

O state fica fora do repositório, em `%USERPROFILE%\.revenda\identidade.tfstate` ([ADR-002](adrs/ADR-002-segredos-terraform-state-externo.md)). O **mesmo arquivo** é usado:

- pelo CD, como `/revenda-state/identidade.tfstate`, pelo bind mount;
- pelo `scripts\windows\04-subir-ambiente.ps1` e pelo `05-destruir-ambiente.ps1`, no Windows.

Por isso a versão do Terraform do PC e a da imagem do runner devem ser a mesma (1.16.4 no Dockerfile). O state da API é outro arquivo, gerenciado só pelo repositório dela. O backend é `local` com configuração parcial: o caminho entra no `terraform init` via `-backend-config`.

### 2.5 Concorrência

`concurrency: deploy-identidade`, sem cancelamento: dois deploys da identidade nunca rodam ao mesmo tempo, e um merge que chega durante um deploy espera a vez. O grupo é diferente do grupo do CD da API, então os dois repositórios podem implantar em paralelo; cada um mexe só no seu namespace e no seu state. O único recurso disputado é a criação do cluster: quem chegar primeiro cria, e o outro encontra o cluster pronto. Não há trava entre os dois repositórios; se os dois CDs tentarem criar o cluster ao mesmo tempo, o `kind create cluster` do segundo falha e o passo espera até 3 minutos pelo cluster que o outro está criando, seguindo com ele.

### 2.6 Rollback

*Actions > CD > Run workflow*, informando em `ref` o SHA de um commit anterior da `main`:

```powershell
gh workflow run cd.yml -R Caina-Climaco/fiap-soat-revenda-identidade -f ref=<sha-anterior>
```

O CD aplica o Terraform daquele commit (imagens, Deployment, Job, ConfigMap). Dois cuidados:

- **o realm não volta sozinho**: com o import `IGNORE_EXISTING`, a versão anterior do `realm-revenda.json` só vale num realm novo. Para desfazer uma mudança de realm é preciso recriar a identidade ou reverter a mudança pela Admin API ([contrato, seção 8](contrato-identidade.md#8-como-o-contrato-muda));
- **os segredos não mudam**: eles estão no state, não no commit.

## 3. Proteção da `main`

Aplicada pelo `scripts\windows\02-criar-repositorio.ps1` (API `branches/main/protection` do GitHub):

| Regra | Valor |
|---|---|
| PR obrigatório | Sim; 0 aprovações exigidas (trabalho individual: o GitHub não deixa o autor aprovar o próprio PR); aprovações antigas descartadas a cada push |
| Checks obrigatórios | `qualidade`, `realm`, `infra`, com a branch atualizada em relação à `main` (`strict`) |
| Vale para administradores | Sim (`enforce_admins`) |
| Histórico linear | Sim |
| Force push e exclusão da `main` | Bloqueados |
| Conversas resolvidas | Obrigatório |

Configurações do repositório aplicadas pelo mesmo script:

- só **squash merge** (merge commit e rebase desligados), com título = título do PR e mensagem = corpo do PR;
- branch apagada após o merge;
- workflows de PRs vindos de forks só rodam com aprovação do dono;
- environment `local`, usado pelo CD.

## 4. Fluxo de Pull Request

1. Faça a mudança no working tree (sem commitar).
2. Abra o PR com o script, que valida o título, cria a branch a partir da `origin/main` levando as mudanças não commitadas, faz commit, push e `gh pr create` com o [template de PR](../.github/pull_request_template.md):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\abrir-pr.ps1 `
     -Branch feat/atributo-perfil -Titulo "feat(realm): novo atributo opcional no perfil" -Acompanhar
   ```
   - `-Acompanhar` segue os checks ao vivo (`gh pr checks --watch`);
   - `-AutoMerge` agenda o squash merge para quando os checks obrigatórios passarem (e liga `allow_auto_merge` no repositório, se preciso);
   - `-Corpo` substitui o template;
   - códigos de saída: 0 ok, 1 erro, 2 PR aberto com checks falhando;
   - log em `.setup\relatorio-pr.txt`.
3. Branches de vida curta: `feat/*`, `fix/*`, `docs/*`, `infra/*` (o script também aceita `ci/*`, `build/*`, `chore/*`, `refactor/*` e `test/*`; outro nome gera só um aviso).
4. Com os checks verdes, o squash merge entra na `main` e dispara o CD. Se o PR já estiver mergeado ao final, o script volta para a `main` e faz `git pull --ff-only`.

Se a mudança altera o contrato, o checklist do template pede a atualização do [contrato](contrato-identidade.md) e o aviso ao repositório da API.

## 5. Por que o runner self-hosted não reage a `pull_request`

O repositório é público. Um runner self-hosted executa o código do workflow na máquina do autor, e este runner tem o socket do Docker montado, o que equivale a privilégio de administrador sobre o Docker do PC, inclusive sobre o cluster. Se algum workflow self-hosted rodasse em `pull_request`, um PR de um fork poderia alterar o workflow e executar qualquer comando nessa máquina.

Por isso:

- o `cd.yml` é o único workflow com `runs-on: [self-hosted, ...]` e só dispara em `push` na `main` e em `workflow_dispatch`, este restrito a commits da `main`;
- todo o CI de PR roda no runner hospedado do GitHub, descartável e sem acesso ao PC;
- workflows de PRs de forks exigem aprovação;
- a proteção da `main` vale também para administradores, então nada chega à `main` sem PR e CI verde.

O resultado é que o runner self-hosted só executa código revisado e já mergeado. O `actionlint` local é configurado em [`.github/actionlint.yaml`](../.github/actionlint.yaml) para reconhecer a label `kind-local`.
