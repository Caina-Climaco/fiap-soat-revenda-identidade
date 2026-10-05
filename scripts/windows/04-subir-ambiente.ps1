# Sobe o servico de identidade no cluster kind local: cria o cluster "revenda" com a CLI
# kind, se faltar (infra/kind/cluster.yaml; o cluster e a plataforma compartilhada, ADR-003),
# e aplica o Terraform DESTE repositorio: namespace identidade, segredos, keycloak-db,
# Keycloak com o realm revenda e o Job de reconciliacao. Nada da API e tocado aqui.
# O CD (.github/workflows/cd.yml) faz o mesmo a cada merge na main.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File .\scripts\windows\04-subir-ambiente.ps1
#
# State: %USERPROFILE%\.revenda\identidade.tfstate (TF_DATA_DIR em
# %USERPROFILE%\.revenda\terraform-data-identidade). O CD usa o MESMO arquivo (o runner
# monta %USERPROFILE%\.revenda em /revenda-state). O state da API e outro arquivo.
# Nunca dentro do repositorio (ADR-002).
# Log: .setup\relatorio-identidade-subir.txt. Arquivo somente ASCII (Windows PowerShell 5.1).
$ErrorActionPreference = "Continue"
# Recarrega o PATH do registro: ferramentas instaladas pelo winget nesta sessao
# (kind, terraform) so aparecem em janelas novas do PowerShell.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:Path
$raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tfDir = Join-Path $raiz "infra\terraform"
$log = Join-Path $raiz ".setup\relatorio-identidade-subir.txt"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null

function Invocar {
    param([string]$Exe, [string[]]$Argumentos)
    Write-Host ">> $Exe $($Argumentos -join ' ')"
    $global:LASTEXITCODE = 0
    & $Exe @Argumentos 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    } | Out-Host
    return $LASTEXITCODE
}

function Falhar([string]$motivo) {
    Write-Host ""
    Write-Host "ERRO: $motivo"
    Write-Host "Log: $log"
    Stop-Transcript | Out-Null
    exit 1
}

# Clusters kind existentes (a mensagem "No kind clusters found." vai para stderr)
function ClustersKind {
    $saida = @(& kind get clusters 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($saida | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

Write-Host "04-subir-ambiente.ps1 (identidade) - $(Get-Date -Format s)"
foreach ($f in @("docker", "kind", "kubectl", "terraform")) {
    if (-not (Get-Command $f -ErrorAction SilentlyContinue)) {
        Falhar "'$f' nao encontrado no PATH (rode scripts\windows\01-instalar-ferramentas.ps1)."
    }
}
if ((Invocar "docker" @("version", "--format", "docker {{.Server.Version}}")) -ne 0) {
    Falhar "Docker Desktop nao responde. Inicie o Docker Desktop e tente de novo."
}

$perfil = $env:USERPROFILE -replace '\\', '/'
$stateDir = "$perfil/.revenda"
$statePath = "$stateDir/identidade.tfstate"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$env:TF_DATA_DIR = "$stateDir/terraform-data-identidade"
$env:TF_IN_AUTOMATION = "1"
$env:TF_INPUT = "0"
$env:KUBECONFIG = "$perfil/.kube/config"
$env:TF_VAR_kubeconfig_path = "$perfil/.kube/config"
Write-Host "State: $statePath | TF_DATA_DIR: $env:TF_DATA_DIR | KUBECONFIG: $env:KUBECONFIG"
if (Test-Path "$stateDir/terraform.tfstate") {
    Write-Host "AVISO: existe $stateDir/terraform.tfstate (state antigo, de quando a identidade e a API"
    Write-Host "       estavam no mesmo repositorio). Veja 'Migracao' no README antes de continuar."
}

# ------------------------------------------------------------------ cluster (CLI kind)
$configKind = Join-Path $raiz "infra\kind\cluster.yaml"
if ((ClustersKind) -contains "revenda") {
    Write-Host "Cluster kind 'revenda' ja existe (nada a criar)."
} else {
    $codigo = Invocar "kind" @("create", "cluster", "--config", $configKind, "--wait", "120s")
    if ($codigo -ne 0) { Falhar "kind create cluster falhou (codigo $codigo)." }
}
if ((Invocar "kind" @("export", "kubeconfig", "--name", "revenda")) -ne 0) { Falhar "kind export kubeconfig falhou." }

# ------------------------------------------------------------------ terraform
$codigo = Invocar "terraform" @("-chdir=$tfDir", "init", "-input=false", "-no-color", "-reconfigure", "-backend-config=path=$statePath")
if ($codigo -ne 0) { Falhar "terraform init falhou (codigo $codigo)." }
$codigo = Invocar "terraform" @("-chdir=$tfDir", "apply", "-input=false", "-no-color", "-auto-approve")
if ($codigo -ne 0) { Falhar "terraform apply falhou (codigo $codigo). Diagnostico: kubectl -n identidade get pods" }

$null = Invocar "kubectl" @("-n", "identidade", "get", "pods,svc,jobs", "-o", "wide")
$null = Invocar "terraform" @("-chdir=$tfDir", "output", "-no-color", "contrato")

$pronto = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8180/realms/revenda/.well-known/openid-configuration" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) { $pronto = $true; break }
    } catch { }
    Start-Sleep -Seconds 5
}
if ($pronto) { Write-Host "Keycloak OK: realm revenda publicado em http://localhost:8180/realms/revenda" }
else { Write-Host "AVISO: o discovery do realm ainda nao respondeu (kubectl -n identidade logs deployment/keycloak)." }

Write-Host ""
Write-Host "================= servico de identidade ================="
Write-Host "Keycloak             http://localhost:8180   (admin: http://localhost:8180/admin/)"
Write-Host "Conta do cliente     http://localhost:8180/realms/revenda/account"
Write-Host "Issuer (contrato)    http://localhost:8180/realms/revenda"
Write-Host ""
Write-Host "Senha do gestor.loja (PowerShell):"
Write-Host '  $b = kubectl -n identidade get secret keycloak-gestor -o jsonpath="{.data.GESTOR_PASSWORD}"'
Write-Host '  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))'
Write-Host ""
Write-Host "Proximo passo: subir a API pelo repositorio fiap-soat-revenda-veiculos."
Write-Host "Log: $log"
Stop-Transcript | Out-Null
exit 0
