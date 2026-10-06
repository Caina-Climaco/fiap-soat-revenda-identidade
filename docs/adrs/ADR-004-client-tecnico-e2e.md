# ADR-004: Client técnico `revenda-e2e-admin` para os testes da API em vez do admin do realm `master`

**Status:** Aceito
**Data:** 2026-10-04

## Contexto

Os testes ponta a ponta da API, executados pelo CD dela contra o ambiente implantado, precisam criar compradores no realm `revenda` (para comprar, testar 403/404/409 etc.) e apagá-los no final. Na versão anterior, eles faziam isso com o **admin bootstrap do realm `master`**: o CD da API lia o Secret `identidade/keycloak-admin` e obtinha um token com `admin-cli`.

Com a identidade num repositório próprio ([ADR-001](ADR-001-keycloak-identidade.md)), isso deixou de ser aceitável:

- a credencial de administração total do Keycloak (todos os realms, clients, chaves e configurações) sairia deste repositório;
- uma falha nos testes da API poderia alterar qualquer coisa na identidade;
- o serviço não seria "totalmente apartado" se o outro repositório tivesse o seu admin.

## Decisão

Criar no realm `revenda` o client confidencial **`revenda-e2e-admin`**, só para o ambiente local:

- só o fluxo *client credentials* (conta de serviço); sem Authorization Code, password grant, *implicit*, *device* ou CIBA;
- a conta de serviço tem **apenas** os papéis `manage-users`, `view-users` e `query-users` do client `realm-management` do realm `revenda`, sem papéis de realm;
- escopos padrão `basic` e `roles`, sem mapper de audiência: o token dele não tem `revenda-api` em `aud` e não serve para chamar a API;
- o segredo vem do placeholder `${E2E_ADMIN_CLIENT_SECRET}`, gerado pelo Terraform e publicado no Secret de contrato `identidade/keycloak-e2e` (chaves `E2E_ADMIN_CLIENT_ID` e `E2E_ADMIN_CLIENT_SECRET`), e é reaplicado pelo Job `keycloak-reconciliar` ([ADR-002](ADR-002-segredos-terraform-state-externo.md));
- o Secret `keycloak-admin` (admin do `master`) passa a ser interno: usado só pelo Job de reconciliação deste repositório.

O CI verifica, via `jq`, que a conta de serviço tem exatamente esses três papéis e que o segredo vem do placeholder. O teste `test_client_tecnico_do_e2e_tem_privilegio_minimo` verifica num Keycloak real que o client lista usuários do realm `revenda`, mas recebe 403 ao listar clients, não acessa o realm `master` e não tem `revenda-api` na audiência nem papéis de negócio.

## Consequências

### Positivas

- A credencial de administração total nunca sai deste repositório.
- O raio de dano de um vazamento do segredo do e2e fica limitado a usuários do realm `revenda`.
- O contrato com a API fica explícito: um Secret com nome e chaves documentados ([contrato, seção 6](../contrato-identidade.md#6-secrets-de-contrato)).

### Negativas

- `manage-users` ainda é um privilégio alto dentro do realm `revenda`: permite criar, alterar e apagar qualquer usuário, inclusive o `gestor.loja`, e também **atribuir papéis de realm a qualquer usuário, inclusive `gestor`** (os *role mappings* de usuário fazem parte de `manage-users`). Quem tiver o segredo do client pode, portanto, promover um comprador a gestor. Isso é aceitável só no ambiente local de demonstração.
- Mais um client e mais um segredo para manter.
- Exigiu uma mudança coordenada nos testes da API (variáveis `E2E_KC_CLIENT_ID` e `E2E_KC_CLIENT_SECRET` no lugar do admin do `master`).

### Mitigações

- O client existe só no ambiente local e está marcado para remoção em produção ([contrato, seção 7](../contrato-identidade.md#7-o-que-é-só-do-ambiente-local)). Em produção, o caminho é inexistir ou ficar desativado; se um ambiente de testes isolado precisar de algo parecido, com papel mínimo (`view-users` e `query-users`) ou um usuário de serviço separado por operação ([contrato, seção 7.1](../contrato-identidade.md#71-ambiente-local-versus-produção)).
- O segredo é gerado pelo Terraform, nunca versionado, e só é lido pelo CD da API, que roda apenas código já mergeado na `main`.
- Se o `gestor.loja` for alterado por engano, o Job `keycloak-reconciliar` restaura a senha e os papéis na próxima execução.

## Alternativas consideradas

| Alternativa | Prós | Contras |
|---|---|---|
| **Client confidencial com conta de serviço de privilégio mínimo** (escolhida) | Escopo limitado ao realm e a usuários; segredo próprio e rotacionável | `manage-users` ainda permite alterar qualquer usuário do realm |
| Admin do realm `master` (versão anterior) | Já funcionava | Credencial de administração total fora deste repositório |
| Usuário humano com papel `realm-admin` no realm `revenda` | Sem client novo | Mais privilégio que o necessário (clients, chaves, configuração do realm); senha de usuário em vez de segredo de client |
| Usuários de teste fixos no `realm-revenda.json` | Sem Admin API | Senhas no realm (ou mais placeholders); os testes não criariam nem apagariam contas; dados de teste permanentes no realm |
| Autocadastro pelo formulário HTML nos testes | Exercita o fluxo real | Frágil (depende do HTML do tema) e não resolve a limpeza dos usuários |
