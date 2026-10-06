# ADR-003: Plataforma kind compartilhada, criada pela CLI kind, com namespace e state por repositório

**Status:** Aceito
**Data:** 2026-10-04

## Contexto

A solução roda num Kubernetes local (kind) no PC do autor, sem nuvem. Com a identidade num repositório próprio ([ADR-001](ADR-001-keycloak-identidade.md)), passam a existir dois repositórios, cada um com o seu Terraform e o seu pipeline, que precisam implantar no mesmo ambiente:

- a API precisa alcançar o JWKS do Keycloak;
- o navegador precisa alcançar a API (porta 8080) e o Keycloak (porta 8180);
- o PC tem memória limitada.

Na versão anterior, o cluster era criado pela CLI kind a partir de `infra/kind/cluster.yaml` no repositório da API. O plano original de criá-lo pelo Terraform, com o provider comunitário `tehcyx/kind`, foi abandonado porque o binário desse provider não tem assinatura de código e é bloqueado pelo **Smart App Control** do Windows 11 ("An Application Control policy has blocked this file"). Desligar o Smart App Control foi descartado. A CLI `kind` e os providers da HashiCorp têm assinatura válida.

## Decisão

- O cluster kind `revenda` é uma **plataforma compartilhada**, como uma conta de nuvem comum aos dois serviços.
- Ele é criado pela **CLI `kind`**, nunca pelo Terraform, a partir de `infra/kind/cluster.yaml`, e esse arquivo é **idêntico nos dois repositórios**: um nó control-plane, imagem do nó fixada por digest (release kind v0.33.0, Kubernetes 1.34), `podSubnet` `10.244.0.0/16` e as portas da plataforma inteira, todas em `127.0.0.1`: 8080 → 30080 (Kong, entrada da API), 8180 → 30180 (Keycloak), 15432 → 30432 (banco da API), 3000 → 30300 (Grafana) e 9090 → 30900 (Prometheus).
- O CD de cada repositório, e o script 04 de cada um, criam o cluster **se ele não existir** (`kind get clusters | grep -qx revenda || kind create cluster --config infra/kind/cluster.yaml --wait 120s`). Quem chegar primeiro cria; o outro encontra o cluster pronto.
- Cada repositório tem **o seu namespace, o seu Terraform e o seu state**. Este repositório gerencia só o namespace `identidade` (`%USERPROFILE%\.revenda\identidade.tfstate`) e não conhece o namespace `revenda` da API. Os providers usam o contexto `kind-revenda` do kubeconfig.
- Mudar o `cluster.yaml` exige PR nos dois repositórios, com o mesmo conteúdo; o job `infra` do CI confere nome, portas e digest.

## Consequências

### Positivas

- Um só cluster no PC: menos memória e as portas 8080 e 8180 sem conflito.
- A API alcança o Keycloak pelo DNS do cluster (`keycloak.identidade.svc.cluster.local`), sem rede extra entre clusters.
- Os dois repositórios ficam independentes no que importa: cada um implanta, destrói e versiona só o seu namespace, com o seu state.
- Qualquer um dos dois pode subir primeiro e criar a plataforma, então nenhum depende de um terceiro repositório "de plataforma".
- Só binários assinados no caminho do deploy.

### Negativas

- O cluster fica fora de qualquer state: mudar o `cluster.yaml` só tem efeito recriando o cluster, o que derruba os dois serviços.
- Os dois arquivos podem divergir se um PR for feito só num repositório; a configuração efetiva é a de quem criou o cluster.
- Apagar o cluster (`05-destruir-ambiente.ps1 -ApagarCluster`) derruba também a API, e o state da API fica desatualizado.
- O `cluster.yaml` deste repositório contém portas e comentários da API (por exemplo, 15432 do banco dela, 3000 do Grafana e 9090 do Prometheus).
- Não há trava entre os dois CDs: se ambos tentarem criar o cluster ao mesmo tempo, o `kind create` do segundo falha e ele passa a esperar (até 3 minutos) pelo cluster criado pelo outro.
- A separação entre os namespaces é de responsabilidade, não de permissão: os dois runners usam o kubeconfig de administrador do kind e, tecnicamente, o CD da API conseguiria ler ou alterar o namespace `identidade`. O contrato define o que ele lê (só os Secrets `keycloak-gestor` e `keycloak-e2e`).

### Mitigações

- O cabeçalho do `cluster.yaml` documenta que o arquivo é idêntico nos dois repositórios e que mudanças exigem PR nos dois.
- O script 05 só apaga o cluster com `-ApagarCluster` e pede confirmação, avisando que a API cai junto.
- Uma falha na criação simultânea do cluster se resolve rodando o CD de novo.
- Para produção, o caminho é uma credencial por pipeline com RBAC limitado ao próprio namespace (e leitura só dos Secrets de contrato) e um cluster gerenciado com namespaces (ou contas) por serviço e a infraestrutura de plataforma num pipeline próprio.

## Alternativas consideradas

| Alternativa | Prós | Contras |
|---|---|---|
| **Cluster kind compartilhado, CLI kind, namespace e state por repositório** (escolhida) | Um cluster; independência por namespace e state; só binários assinados | `cluster.yaml` duplicado; o cluster fica fora do Terraform |
| Um cluster kind por repositório | Isolamento total | Dobro de memória; as portas do host teriam de mudar; a API precisaria alcançar o JWKS de outro cluster pelo host |
| Repositório "de plataforma" só para o cluster | Dono único do `cluster.yaml` | Terceiro repositório e terceiro pipeline para um arquivo de cerca de 50 linhas |
| Cluster criado pelo Terraform (`tehcyx/kind`) num dos repositórios | Cluster no state | Provider bloqueado pelo Smart App Control; um repositório passaria a ser dono da plataforma do outro |
| Tudo num repositório só (versão anterior) | Simples | O serviço de identidade não seria "totalmente apartado" |
