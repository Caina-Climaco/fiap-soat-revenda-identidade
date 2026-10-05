"""Apoio dos testes do realm ``revenda`` (contrato publicado em docs/contrato-identidade.md).

Rodam contra um Keycloak em execucao:

- no CI, o ``docker-compose.yml`` deste repositorio (Keycloak + PostgreSQL proprios);
- no CD, o Keycloak implantado no cluster kind.

Variaveis de ambiente:

=========================  ===========  ===============================================
Variavel                   Obrigatoria  Uso
=========================  ===========  ===============================================
KEYCLOAK_URL               nao          Base do Keycloak (padrao http://localhost:8180)
OIDC_ISSUER_ESPERADO       nao          ``iss`` esperado (padrao http://localhost:8180/realms/revenda)
GESTOR_PASSWORD            sim          Senha do usuario seed ``gestor.loja``
E2E_ADMIN_CLIENT_SECRET    sim          Segredo do client tecnico ``revenda-e2e-admin``
=========================  ===========  ===============================================
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import time
import uuid
from collections.abc import Iterator
from typing import Any

import httpx
import pytest

REALM = "revenda"
TIMEOUT = httpx.Timeout(20.0, connect=5.0)
OBRIGATORIAS = ("GESTOR_PASSWORD", "E2E_ADMIN_CLIENT_SECRET")


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    ausentes = [v for v in OBRIGATORIAS if not os.environ.get(v)]
    if ausentes:
        raise pytest.UsageError(f"defina {', '.join(ausentes)} (ver README, secao 'Como testar')")


def claims(token: str) -> dict[str, Any]:
    """Payload de um JWT, sem verificar a assinatura (so para inspecionar o conteudo)."""
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def gerar_cpf() -> str:
    """CPF ficticio com digitos verificadores validos (formato aceito pelo realm)."""
    base = [secrets.randbelow(10) for _ in range(9)]
    for tamanho in (9, 10):
        soma = sum(d * (tamanho + 1 - i) for i, d in enumerate(base))
        resto = (soma * 10) % 11
        base.append(0 if resto == 10 else resto)
    return "".join(map(str, base))


class Keycloak:
    def __init__(self, url: str, http: httpx.Client) -> None:
        self.url = url.rstrip("/")
        self.http = http
        self.criados: list[str] = []

    @property
    def realm_url(self) -> str:
        return f"{self.url}/realms/{REALM}"

    def token_senha(self, usuario: str, senha: str) -> str:
        r = self.http.post(
            f"{self.realm_url}/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id": "revenda-e2e",
                "username": usuario,
                "password": senha,
                "scope": "openid",
            },
        )
        assert r.status_code == 200, f"token de {usuario}: {r.status_code} {r.text[:300]}"
        return str(r.json()["access_token"])

    def token_admin_e2e(self) -> str:
        r = self.http.post(
            f"{self.realm_url}/protocol/openid-connect/token",
            data={
                "grant_type": "client_credentials",
                "client_id": "revenda-e2e-admin",
                "client_secret": os.environ["E2E_ADMIN_CLIENT_SECRET"],
            },
        )
        assert r.status_code == 200, (
            f"client_credentials revenda-e2e-admin: {r.status_code} {r.text[:300]}"
        )
        return str(r.json()["access_token"])

    def admin(self, metodo: str, caminho: str, **kw: Any) -> httpx.Response:
        cab = {"Authorization": f"Bearer {self.token_admin_e2e()}"}
        return self.http.request(
            metodo, f"{self.url}/admin/realms/{REALM}{caminho}", headers=cab, **kw
        )

    def criar_usuario(self, **extra: Any) -> tuple[httpx.Response, str, str]:
        username = f"teste-{uuid.uuid4().hex[:10]}"
        senha = f"Tst!{secrets.token_urlsafe(10)}9aZ"
        corpo: dict[str, Any] = {
            "username": username,
            "email": f"{username}@teste.revenda.local",
            "emailVerified": True,
            "enabled": True,
            "firstName": "Pessoa",
            "lastName": "de Teste",
            "attributes": {"cpf": [gerar_cpf()], "telefone": ["11987654321"]},
            "requiredActions": [],
            "credentials": [{"type": "password", "value": senha, "temporary": False}],
        }
        corpo.update(extra)
        r = self.admin("POST", "/users", json=corpo)
        if r.status_code == 201:
            self.criados.append(r.headers["location"].rstrip("/").rsplit("/", 1)[-1])
        return r, username, senha

    def limpar(self) -> None:
        for uid in self.criados:
            self.admin("DELETE", f"/users/{uid}")
        self.criados.clear()


@pytest.fixture(scope="session")
def kc() -> Iterator[Keycloak]:
    url = os.environ.get("KEYCLOAK_URL", "http://localhost:8180")
    with httpx.Client(timeout=TIMEOUT) as http:
        limite = time.monotonic() + 300
        while True:
            try:
                if (
                    http.get(f"{url}/realms/{REALM}/.well-known/openid-configuration").status_code
                    == 200
                ):
                    break
            except httpx.HTTPError:
                pass
            if time.monotonic() > limite:
                pytest.fail(f"Keycloak sem o realm {REALM} em {url} apos 300 s")
            time.sleep(5)
        k = Keycloak(url, http)
        yield k
        k.limpar()
