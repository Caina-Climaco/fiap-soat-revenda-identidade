# Architecture Decision Records

Registro das decisões de arquitetura do serviço de identidade. Cada ADR descreve o contexto, a decisão, as consequências e as alternativas consideradas.

As decisões da API (monólito modular, stack, pagamento por webhook, concorrência etc.) estão nos ADRs do [repositório da API](https://github.com/Caina-Climaco/fiap-soat-revenda-veiculos/tree/main/docs/adrs). A numeração aqui é própria deste repositório.

| Nº | Decisão | Status |
|---|---|---|
| [ADR-001](ADR-001-keycloak-identidade.md) | Keycloak como serviço de identidade apartado | Aceito |
| [ADR-002](ADR-002-segredos-terraform-state-externo.md) | Segredos gerados pelo Terraform e state fora do repositório | Aceito |
| [ADR-003](ADR-003-plataforma-kind-compartilhada.md) | Plataforma kind compartilhada, criada pela CLI kind, com namespace e state por repositório | Aceito |
| [ADR-004](ADR-004-client-tecnico-e2e.md) | Client técnico `revenda-e2e-admin` para os testes da API em vez do admin do realm `master` | Aceito |
| [ADR-005](ADR-005-runner-self-hosted-container.md) | Runner self-hosted em container Linux, um por repositório | Aceito |
