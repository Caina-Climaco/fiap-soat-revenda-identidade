# ADR-001: Keycloak como serviço de identidade apartado

**Status:** Aceito
**Data:** 2026-10-03 (revisado em 2026-10-04, com a identidade em repositório próprio)

## Contexto

O enunciado exige que o registro e a autorização dos compradores sejam feitos num serviço **totalmente apartado** do restante da solução, para que os dados de clientes fiquem separados dos dados transacionais das vendas. Ele cita Auth0, Cognito, Keycloak ou uma implementação própria.

Restrições do projeto:

- trabalho individual, com prazo curto;
- sem conta de nuvem disponível: todo o ambiente roda num Kubernetes local (kind) no PC do autor ([ADR-003](ADR-003-plataforma-kind-compartilhada.md));
- a API, em outro repositório, precisa validar tokens sem conhecer os dados cadastrais.

Na primeira versão, o Keycloak era implantado pelo repositório da API: outro namespace e outro banco, mas o mesmo Terraform, o mesmo state e o mesmo pipeline. A API, portanto, ainda tinha acesso às credenciais de administração da identidade. Esta revisão leva o serviço para um repositório próprio.

## Decisão

Adotar o **Keycloak 26.7.1** (imagem oficial `quay.io/keycloak/keycloak:26.7.1`, tag fixada), com um **PostgreSQL 16 exclusivo** (`keycloak-db`), no namespace `identidade`, implantado e operado **só por este repositório**, que tem código, Terraform, state, CI, CD e runner próprios.

A configuração fica no realm `revenda`, versionado em `keycloak/realm-revenda.json` e importado na inicialização:

- autocadastro, login por e-mail, e-mail único, proteção contra força bruta, política de senha;
- papéis de realm `cliente` (padrão de todo autocadastro, via `default-roles-revenda`) e `gestor`;
- perfil de usuário declarativo com nome, sobrenome, e-mail, `cpf` obrigatório (11 dígitos) e `telefone` opcional (10 ou 11 dígitos);
- client público `revenda-swagger` (Authorization Code + PKCE S256);
- client `revenda-api`, só como audiência, com mapper de audiência nos clients públicos;
- clients `revenda-e2e` (password grant) e `revenda-e2e-admin` (client credentials, [ADR-004](ADR-004-client-tecnico-e2e.md)), só para os testes do ambiente local;
- escopos `profile` e `email` apenas opcionais: o access token carrega `sub`, papéis e audiência, sem nome, e-mail, CPF ou telefone.

Os consumidores só usam o contrato publicado em [docs/contrato-identidade.md](../contrato-identidade.md): issuer fixo `http://localhost:8180/realms/revenda`, JWKS com chaves RS256, audiência `revenda-api`, papéis e dois Secrets para os testes da API. A API valida os tokens pelo JWKS e guarda apenas o `sub`.

## Consequências

### Positivas

- A segregação dos dados pessoais é física e organizacional: outro processo, outro banco, outro namespace, outro repositório e outro pipeline. O Terraform e o CD da API não gerenciam nenhum recurso da identidade e não usam as credenciais de administração; o que a API pode ler está listado no contrato.
- Cadastro, login, gestão de sessão, proteção contra força bruta, página de conta do titular e exclusão de conta vêm prontos e mantidos pela comunidade.
- Padrão aberto (OIDC): trocar por Cognito ou Auth0 no futuro exige, na API, só mudar issuer, JWKS e audiência.
- O contrato é testado contra um Keycloak real no CI e no ambiente implantado.

### Negativas

- Mais um componente para operar e mais memória no cluster (JVM; *limit* de 1536 MiB).
- O Keycloak não garante unicidade de atributos customizados, como o CPF.
- No ambiente local ele roda em `start-dev` (HTTP, sem cache distribuído, uma réplica), com `sslRequired: "none"` no realm e `KC_HOSTNAME=http://localhost:8180`: escolhas de demonstração, não de produção.
- O import do realm é `IGNORE_EXISTING`: mudanças no JSON não chegam a um realm já criado.
- Dois repositórios exigem coordenação quando o contrato muda.

### Mitigações

- *Request* de 768 MiB e *limit* de 1536 MiB; heap no padrão da imagem (percentual da memória do container). A *startup probe* tolera até 10 minutos na primeira subida, e a *readiness probe* evita tráfego antes de o realm estar importado.
- O e-mail é o identificador único; o formato do CPF é validado pelo perfil; a unicidade do CPF fica registrada como limitação conhecida.
- O Job `keycloak-reconciliar` mantém a senha do gestor e o segredo do client técnico iguais aos Secrets, apesar do `IGNORE_EXISTING`. Outras mudanças no realm exigem recriar a identidade ou usar a Admin API, como descrito no contrato.
- Mudanças de contrato seguem o processo do [contrato, seção 8](../contrato-identidade.md#8-como-o-contrato-muda): PR aqui, PR coordenado na API, identidade primeiro.
- Para produção: `start --optimized` com TLS (`sslRequired: external` ou `all`), `KC_HOSTNAME` público e cache distribuído; remover ou desativar `revenda-e2e` e `revenda-e2e-admin`; restringir na API os clients aceitos (`OIDC_AZP_PERMITIDOS`, cujo padrão aceita `revenda-swagger` e `revenda-e2e`). A lista completa, item a item e com os arquivos e linhas envolvidos, está no [contrato, seção 7.1 "Ambiente local versus produção"](../contrato-identidade.md#71-ambiente-local-versus-produção).

## Alternativas consideradas

| Alternativa | Prós | Contras |
|---|---|---|
| **Keycloak self-hosted em repositório próprio** (escolhida) | OIDC/OAuth 2.0 completo; autocadastro, papéis e perfil prontos; roda em container; custo zero; banco próprio; separação total do resto da solução | Mais memória; realm precisa ser versionado; coordenação entre repositórios |
| Keycloak no repositório da API (versão anterior) | Um só pipeline e um só state | A API conhecia as credenciais de administração da identidade e um deploy da API podia recriar o Keycloak: não é "totalmente apartado" |
| Amazon Cognito | Gerenciado | Exige conta AWS, indisponível; não roda localmente |
| Auth0 | Gerenciado; boa experiência para o desenvolvedor | Dependência de SaaS externo; plano gratuito limitado; os dados pessoais ficariam com um operador externo |
| Implementação própria | Controle total | Reimplementar hash de senha, emissão e rotação de chaves, sessão e proteção contra força bruta: alto risco e nenhum ganho para o objetivo do trabalho |
