"""Contrato do realm ``revenda`` (docs/contrato-identidade.md), testado num Keycloak real."""

from __future__ import annotations

import os
import re

import pytest

from conftest import Keycloak, claims

pytestmark = pytest.mark.realm

ISSUER = os.environ.get("OIDC_ISSUER_ESPERADO", "http://localhost:8180/realms/revenda")
DADOS_PESSOAIS = (
    "email",
    "name",
    "given_name",
    "family_name",
    "preferred_username",
    "cpf",
    "telefone",
)


def test_discovery_publica_issuer_e_jwks(kc: Keycloak) -> None:
    doc = kc.http.get(f"{kc.realm_url}/.well-known/openid-configuration").json()
    assert doc["issuer"] == ISSUER
    assert doc["jwks_uri"].endswith("/realms/revenda/protocol/openid-connect/certs")
    jwks = kc.http.get(f"{kc.realm_url}/protocol/openid-connect/certs").json()
    assert any(k.get("alg") == "RS256" and k.get("use") == "sig" for k in jwks["keys"])


def test_token_do_gestor_tem_papel_gestor_audiencia_e_nenhum_dado_pessoal(
    kc: Keycloak,
) -> None:
    c = claims(kc.token_senha("gestor.loja", os.environ["GESTOR_PASSWORD"]))
    assert c["iss"] == ISSUER
    aud = c["aud"] if isinstance(c["aud"], list) else [c["aud"]]
    assert "revenda-api" in aud
    papeis = c["realm_access"]["roles"]
    assert "gestor" in papeis
    assert "cliente" not in papeis, "o gestor nao compra (RN-05)"
    assert re.fullmatch(r"[0-9a-f-]{36}", c["sub"])
    assert not [k for k in DADOS_PESSOAIS if k in c], (
        "minimizacao (LGPD): token so com sub e papeis"
    )


def test_cliente_cadastrado_recebe_papel_cliente_e_token_sem_dados_pessoais(
    kc: Keycloak,
) -> None:
    r, usuario, senha = kc.criar_usuario()
    assert r.status_code == 201, r.text[:300]
    c = claims(kc.token_senha(usuario, senha))
    assert "cliente" in c["realm_access"]["roles"]
    assert "gestor" not in c["realm_access"]["roles"]
    assert not [k for k in DADOS_PESSOAIS if k in c]
    # Os dados pessoais existem, mas so aqui, no servico de identidade
    uid = r.headers["location"].rstrip("/").rsplit("/", 1)[-1]
    assert c["sub"] == uid
    dados = kc.admin("GET", f"/users/{uid}").json()
    assert dados["attributes"]["cpf"][0].isdigit()
    assert dados["attributes"]["telefone"] == ["11987654321"]


@pytest.mark.parametrize(
    ("atributos", "campo"),
    [
        ({"telefone": ["11987654321"]}, "cpf"),  # CPF obrigatorio
        ({"cpf": ["123"]}, "cpf"),  # CPF com 11 digitos
        (
            {"cpf": ["12345678900"], "telefone": ["12-3456"]},
            "telefone",
        ),  # so digitos, DDD + numero
    ],
)
def test_perfil_rejeita_cpf_ausente_ou_invalido_e_telefone_invalido(
    kc: Keycloak, atributos: dict[str, list[str]], campo: str
) -> None:
    r, _u, _s = kc.criar_usuario(attributes=atributos)
    assert r.status_code == 400, f"esperado 400 por {campo}: {r.status_code} {r.text[:300]}"
    assert campo in r.text


def test_formulario_de_autocadastro_pede_cpf_e_telefone(kc: Keycloak) -> None:
    r = kc.http.get(
        f"{kc.realm_url}/protocol/openid-connect/registrations",
        params={
            "client_id": "revenda-swagger",
            "response_type": "code",
            "scope": "openid",
            "redirect_uri": "http://localhost:8080/docs/oauth2-redirect",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
        },
    )
    assert r.status_code == 200, r.text[:300]
    assert 'name="cpf"' in r.text
    assert 'name="telefone"' in r.text


def test_client_tecnico_do_e2e_tem_privilegio_minimo(kc: Keycloak) -> None:
    token = kc.token_admin_e2e()
    cab = {"Authorization": f"Bearer {token}"}
    # Gerencia usuarios do realm revenda...
    assert kc.http.get(f"{kc.url}/admin/realms/revenda/users?max=1", headers=cab).status_code == 200
    # ...mas nao le clients/segredos nem administra outros realms
    assert kc.http.get(f"{kc.url}/admin/realms/revenda/clients", headers=cab).status_code == 403
    assert kc.http.get(f"{kc.url}/admin/realms/master/users?max=1", headers=cab).status_code in (
        401,
        403,
    )
    # e o token dele nao serve para a API (audiencia errada, nenhum papel de negocio)
    c = claims(token)
    aud = c.get("aud", [])
    assert "revenda-api" not in (aud if isinstance(aud, list) else [aud])
    assert not {"cliente", "gestor"} & set(c.get("realm_access", {}).get("roles", []))
