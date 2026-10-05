## O que muda

<!-- Descreva a mudança em 1 a 3 frases. -->

## Por que

<!-- Qual requisito ou ADR motiva a mudança. -->

## Tipo

- [ ] feat — funcionalidade (realm, perfil, clients)
- [ ] fix — correção
- [ ] infra — Terraform, pipelines, scripts
- [ ] docs — documentação
- [ ] test / refactor / chore

## Checklist

- [ ] Título do PR segue Conventional Commits (`feat: ...`, `fix: ...`)
- [ ] `tests/test_realm.py` cobre a mudança no contrato do realm
- [ ] Mudança no contrato (issuer, audiência, papéis, clients) anotada em `docs/contrato-identidade.md` e avisada ao repositório da API
- [ ] Nenhum segredo, kubeconfig, `.env` ou `tfstate` adicionado
