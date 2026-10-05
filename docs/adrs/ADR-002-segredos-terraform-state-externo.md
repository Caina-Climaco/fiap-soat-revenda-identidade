# ADR-002: Segredos gerados pelo Terraform e state fora do repositório

**Status:** Aceito
**Data:** 2026-10-04

## Contexto

O serviço de identidade precisa de quatro segredos:

- a senha do banco `keycloak-db`;
- a senha do admin bootstrap do Keycloak (realm `master`);
- a senha do usuário seed `gestor.loja`;
- o segredo do client técnico `revenda-e2e-admin`.

Os dois últimos também precisam entrar no realm, que é um arquivo JSON versionado, e ser lidos pelo CD da API para os testes ponta a ponta. O repositório é público. Numa fase anterior do curso, credenciais, kubeconfig e arquivos `terraform.tfstate` chegaram a ser commitados. Não há conta de nuvem, então não há cofre de segredos nem backend remoto de state disponível.

## Decisão

- O Terraform gera todos os segredos com `random_password` (`infra/terraform/secrets.tf`) e os entrega como Secrets no namespace `identidade`: `keycloak-db-credentials`, `keycloak-admin`, `keycloak-gestor` e `keycloak-e2e`.
- Senhas de banco e do admin e o segredo do client usam só letras e dígitos (seguros em URL, JDBC e shell). A senha do gestor usa também `!#%*-_=+`, sem aspas, barra invertida, `$`, `{` ou `}`, porque entra no arquivo de realm por substituição de texto.
- O `realm-revenda.json` só contém os placeholders `${GESTOR_PASSWORD}` e `${E2E_ADMIN_CLIENT_SECRET}`; o Keycloak os substitui pelas variáveis de ambiente do container, que vêm dos Secrets, no momento do import. O CI falha se os placeholders forem trocados por valores.
- O **state fica fora do repositório**, em `%USERPROFILE%\.revenda\identidade.tfstate`, com backend `local` e configuração parcial (`terraform init -backend-config=path=...`). O mesmo arquivo é usado pelos scripts 04 e 05 e pelo CD (bind mount em `/revenda-state`). O state da API é outro arquivo.
- Nenhuma saída do Terraform contém senha, nem como `sensitive`; o output `comandos_segredos` mostra como lê-las com `kubectl`.
- O `.gitignore` bloqueia `*.tfstate*`, `.terraform/`, `.env`, kubeconfig e chaves. O `.env.example` traz só valores de exemplo.
- No CI, o job `realm` gera segredos aleatórios a cada execução, mascarados no log, e o Trivy procura segredos no repositório em todo PR.
- Rotação: `terraform apply -replace=random_password.<nome>`. O Job `keycloak-reconciliar` reaplica a senha do gestor e o segredo do client técnico no realm existente.

## Consequências

### Positivas

- O repositório público não contém nenhuma credencial utilizável.
- Cada ambiente (cada PC, cada execução do CI) tem os seus próprios segredos.
- Os consumidores leem os segredos de contrato direto do cluster; nada precisa ser copiado à mão para o GitHub.
- Rotação da senha do gestor e do segredo do client sem recriar o realm.

### Negativas

- O state local contém os segredos em texto claro.
- Backend `local` não tem *locking*: um `terraform apply` pelo script 04 ao mesmo tempo que o CD pode corromper o state.
- O Terraform do Windows e o do runner precisam ser da mesma versão, porque compartilham o state.
- O admin bootstrap só é criado na primeira subida do Keycloak: rotacionar `keycloak_admin` exige recriar o `keycloak-db`.
- Se o state for perdido com o banco preservado, o próximo `apply` gera segredos novos; o Job de reconciliação cobre o gestor e o client técnico, mas não a senha do banco nem a do admin.

### Mitigações

- O state fica num diretório do usuário, fora de qualquer repositório, e é removido pelo script 05.
- O CD usa `concurrency` para nunca rodar dois deploys da identidade ao mesmo tempo; o script 04 é para a primeira subida e para uso manual.
- A versão do Terraform está fixada no Dockerfile do runner (1.16.4) e documentada.
- Para produção, o caminho é backend remoto criptografado com *locking* e um cofre de segredos (External Secrets ou equivalente).

## Alternativas consideradas

| Alternativa | Prós | Contras |
|---|---|---|
| **`random_password` → Secrets, state local fora do repositório** (escolhida) | Nada no Git; recriável; sem infraestrutura extra | Segredos em texto claro no state; sem *locking* |
| Secrets versionados em YAML ou valores no `realm-revenda.json` | Simples | Vazamento garantido em repositório público |
| Sealed Secrets ou External Secrets | Padrão de mercado | Mais componentes no cluster; External Secrets exige cofre externo |
| GitHub Secrets injetados pelo CD | Centralizado no GitHub | Segredos criados e rotacionados à mão; o script 04 local não teria acesso a eles |
| Backend remoto (S3, Terraform Cloud) | *Locking*, criptografia | Exige conta de nuvem ou SaaS, indisponível |
