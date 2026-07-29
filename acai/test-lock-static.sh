#!/usr/bin/env bash
# Acai P4-3A — teste determinístico estático do source-lock.
# Rejeita referências mutáveis e inputs fora do lock. Roda em bash puro
# (sem jq) para poder executar antes do bootstrap e em revisão local.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
err() { printf '::error::test-lock-static: %s\n' "$*"; fail=1; }

FILES_CI=".github/workflows/acai-machine-runner-probe.yml"
FILES_SH="acai/verify-lock.sh acai/build-applehv.sh acai/test-lock-static.sh"
LOCK="acai/lock.json"

# 1. Só o workflow do probe pode existir.
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$wf" ] || continue
  [ "$wf" = "$FILES_CI" ] || err "workflow não autorizado presente: $wf"
done

# 2. Toda action usada deve ser pinada por SHA de 40 hex.
while IFS= read -r line; do
  ref="${line#*uses:}"; ref="${ref%%#*}"; ref="$(echo "$ref" | tr -d ' ')"
  case "$ref" in
    *@*) sha="${ref##*@}"
         echo "$sha" | grep -qE '^[0-9a-f]{40}$' || err "action sem SHA de 40 hex: $ref" ;;
    *)   err "action sem pin: $ref" ;;
  esac
done < <(grep -h 'uses:' $FILES_CI)

# 3. Referências mutáveis proibidas no caminho de build.
BAD='(:latest|--latestfrom|koji |list-sidetags|mirrorlist|metalink|releases/latest|fedora-coreos:stable|fedora-coreos:next|fedora-coreos:testing)'
for f in $FILES_CI $FILES_SH; do
  if grep -nE "$BAD" "$f" | grep -vE "BAD='|lockcheck-ok" ; then
    err "referência mutável em $f (acima)"
  fi
done
# Patches: só linhas ADICIONADAS podem ser exigidas limpas (contexto é do upstream).
for f in acai/patches/*.patch; do
  if grep -E '^\+' "$f" | grep -nE "$BAD" ; then
    err "referência mutável ADICIONADA por $f (acima)"
  fi
done

# 4. Imagens de container no workflow devem ser referenciadas por digest.
if grep -E 'image:' "$FILES_CI" | grep -vqE '@sha256:[0-9a-f]{64}'; then
  err "imagem de container sem digest no workflow"
fi

# 5. Lock: sha256 de 64 hex, commits de 40 hex, hosts na allowlist.
grep -oE '"sha256": "[^"]*"' "$LOCK" | grep -vqE '"[0-9a-f]{64}"$' && err "sha256 inválido no lock" || true
grep -oE '"(commit|gitlink)": "[^"]*"' "$LOCK" | grep -vqE '"[0-9a-f]{40}"$' && err "commit/gitlink inválido no lock" || true
while IFS= read -r url; do
  host="$(echo "$url" | sed -E 's|https://([^/]+)/.*|\1|')"
  case "$host" in
    dl.fedoraproject.org|download.copr.fedorainfracloud.org|quay.io|github.com) : ;;
    *) err "host fora da allowlist no lock: $host" ;;
  esac
  case "$url" in https://*) : ;; *) err "URL não-https no lock: $url" ;; esac
done < <(grep -oE '"url": "[^"]*"' "$LOCK" | cut -d'"' -f4)

# 6. O workflow não pode conter permissões/ações de publicação.
FORB='(packages:[[:space:]]*write|id-token:[[:space:]]*write|attestations:[[:space:]]*write|podman login|docker login|buildah login|push |actions/upload-artifact|actions/cache)'
if grep -nE "$FORB" "$FILES_CI"; then
  err "capacidade de publicação/persistência no workflow (acima)"
fi

# 7. Gatilho: somente workflow_dispatch, sem inputs.
grep -q 'workflow_dispatch' "$FILES_CI" || err "workflow_dispatch ausente"
grep -qE '^[[:space:]]*(push|pull_request|schedule|release):' "$FILES_CI" && err "gatilho automático proibido presente" || true
grep -qE '^[[:space:]]*inputs:' "$FILES_CI" && err "inputs livres proibidos no dispatch" || true

# 8. Cada patch em acai/patches/ deve ter seu sha256 real registrado no lock.
for p in acai/patches/*.patch; do
  [ -e "$p" ] || { err "nenhum patch encontrado"; break; }
  psha="$(sha256sum "$p" | cut -d' ' -f1)"
  grep -q "$psha" "$LOCK" || err "sha256 real de $p não consta no lock"
done

# 9. O digest do container do workflow deve constar no lock.
wf_digest="$(grep -oE 'image:.*@sha256:[0-9a-f]{64}' "$FILES_CI" | grep -oE 'sha256:[0-9a-f]{64}')"
[ -n "$wf_digest" ] || err "container do workflow sem digest"
grep -q "$wf_digest" "$LOCK" || err "digest do container do workflow não consta no lock"

if [ "$fail" -ne 0 ]; then
  echo "::error::test-lock-static: FALHOU"
  exit 42
fi
echo "test-lock-static: OK"
