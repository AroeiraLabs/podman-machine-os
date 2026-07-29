#!/usr/bin/env bash
# Acai P4-3A — verificação fail-closed do source-lock ANTES do build.
# Tudo que o build consome é conferido aqui: fonte git, submódulo, patches
# (por sha256), manifests OCI (índice, relação índice→filho e plataforma),
# RPMs (sha256 + assinatura) e chaves. Qualquer divergência => exit 42.
set -uo pipefail

LOCK="acai/lock.json"
WORK="${ACAI_WORK:-/var/tmp/acai}"
SRC="$WORK/src"
RPMS="$WORK/rpms"
KEYS="$WORK/keys"

die() { printf '::error::ACAI P4-3A STOP: %s\n' "$*"; exit 42; }
note() { printf '::notice::%s\n' "$*"; }

command -v jq >/dev/null || die "jq ausente"
command -v git >/dev/null || die "git ausente"
command -v curl >/dev/null || die "curl ausente"

mkdir -p "$SRC" "$RPMS" "$KEYS" || die "não foi possível criar diretórios de trabalho"

# ---------- 1. Ambiente ----------
[ "$(uname -m)" = "aarch64" ] || die "runner não é aarch64: $(uname -m)"
. /etc/os-release || die "sem /etc/os-release"
[ "${VERSION_ID:-}" = "$(jq -r .target.fedora_version "$LOCK")" ] \
  || die "container de build não é Fedora $(jq -r .target.fedora_version "$LOCK"): ${VERSION_ID:-?}"

# ---------- 2. Fonte git pinada ----------
COMMIT=$(jq -r .source.commit "$LOCK")
REPO_URL="https://github.com/$(jq -r .source.repo "$LOCK")"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet "$REPO_URL" "$SRC" || die "clone da fonte falhou"
fi
git -C "$SRC" checkout --quiet "$COMMIT" || die "checkout do commit pinado falhou"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || die "HEAD da fonte difere do lock"

SUB_PATH=$(jq -r '.source.submodules[0].path' "$LOCK")
GITLINK=$(jq -r '.source.submodules[0].gitlink' "$LOCK")
TREE_GITLINK=$(git -C "$SRC" ls-tree HEAD "$SUB_PATH" | awk '{print $3}')
[ "$TREE_GITLINK" = "$GITLINK" ] || die "gitlink no tree ($TREE_GITLINK) difere do lock ($GITLINK)"
git -C "$SRC" submodule update --quiet --init "$SUB_PATH" || die "submodule update falhou"
[ "$(git -C "$SRC/$SUB_PATH" rev-parse HEAD)" = "$GITLINK" ] || die "submódulo checked-out difere do gitlink"

# ---------- 3. Patches: sha256 do lock e aplicação limpa ----------
while IFS=$'\t' read -r pfile psha; do
  [ -f "$pfile" ] || die "patch declarado não existe: $pfile"
  echo "$psha  $pfile" | sha256sum -c - >/dev/null 2>&1 || die "sha256 do patch difere do lock: $pfile"
  git -C "$SRC" apply --check "$(pwd)/$pfile" || die "patch não aplica limpo: $pfile"
  note "patch conferido: $pfile"
done < <(jq -r '.source.patches[] | [.file, .sha256] | @tsv' "$LOCK")

# ---------- 4. OCI: índice íntegro, filho listado no índice, plataforma arm64 ----------
check_oci() {
  local name="$1" ref idx child token body listed plat
  ref=$(jq -r ".oci.${name}.ref" "$LOCK")
  idx=$(jq -r ".oci.${name}.index_digest" "$LOCK")
  child=$(jq -r ".oci.${name}.arm64_digest" "$LOCK")
  case "$ref" in quay.io/*) : ;; *) die "registry fora da allowlist: $ref" ;; esac
  local repo="${ref#quay.io/}"
  token=$(curl -fsS "https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull" | jq -r .token) \
    || die "token do registry falhou para $ref"
  body=$(curl -fsS -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://quay.io/v2/${repo}/manifests/${idx}") || die "índice OCI irrecuperável: $ref@$idx"
  [ "sha256:$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)" = "$idx" ] \
    || die "conteúdo do índice difere do digest: $ref@$idx"
  listed=$(printf '%s' "$body" | jq -r \
    '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="arm64") | .digest') \
    || die "índice sem entrada linux/arm64: $ref"
  [ "$listed" = "$child" ] || die "filho arm64 do índice ($listed) difere do lock ($child) para $ref"
  body=$(curl -fsS -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://quay.io/v2/${repo}/manifests/${child}") || die "manifesto filho irrecuperável: $ref@$child"
  [ "sha256:$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)" = "$child" ] \
    || die "conteúdo do filho difere do digest: $ref@$child"
  note "OCI ok ($name): $ref índice=$idx filho-arm64=$child (relação e plataforma provadas)"
}
check_oci build_container
check_oci fcos_base

# Downloads pinados: seguir redirect é necessário (o COPR responde 301 para o
# seu storage Pulp/S3) e é seguro porque a integridade não vem da origem e sim
# do SHA-256 do lock e, nos RPMs, também da assinatura conferida por rpm -Kv.
# https obrigatório e no máximo 3 saltos; a URL efetiva é registrada.
fetch_pinned() {
  curl -fsSL --proto '=https' --max-redirs 3 -o "$1" -w '%{url_effective}' "$2"
}

# ---------- 5. Chaves GPG pinadas ----------
while IFS=$'\t' read -r kid kurl ksha; do
  [ "$kurl" = "null" ] && continue
  fetch_pinned "$KEYS/$kid.gpg" "$kurl" >/dev/null || die "download da chave falhou: $kid"
  echo "$ksha  $KEYS/$kid.gpg" | sha256sum -c - >/dev/null 2>&1 || die "sha256 da chave difere do lock: $kid"
  rpm --import "$KEYS/$kid.gpg" || die "import da chave falhou: $kid"
  note "chave importada: $kid"
done < <(jq -r '.gpg_keys[] | [.id, (.url // "null"), (.sha256 // "")] | @tsv' "$LOCK")

# ---------- 6. RPMs pinados: download + sha256 + assinatura ----------
while IFS=$'\t' read -r name url sha; do
  f="$RPMS/$(basename "$url")"
  eff=$(fetch_pinned "$f" "$url") || die "download do RPM falhou: $name"
  case "$eff" in "$url") : ;; *) note "redirect seguido ($name): origem declarada -> storage do provedor" ;; esac
  echo "$sha  $f" | sha256sum -c - >/dev/null 2>&1 || die "sha256 difere do lock: $name"
  # Autoridade é o código de saída do rpm (falha em NOKEY/assinatura inválida);
  # o padrão do texto é frouxo porque a redação de rpm -Kv varia por versão.
  sigout=$(rpm -Kv "$f" 2>&1) || die "assinatura inválida ou chave ausente: $name — $(echo "$sigout" | tail -3 | tr '\n' ' ')"
  echo "$sigout" | grep -qiE 'signature.*OK' \
    || die "sem linha de assinatura OK: $name — $(echo "$sigout" | tail -3 | tr '\n' ' ')"
  # Fingerprint efetiva da chave que assinou este RPM.
  # Aceita "key fingerprint: <40 hex>" (rpm atual) e "key ID <8+ hex>" (legado).
  got_fp=$(echo "$sigout" | grep -oiE 'key (fingerprint|ID)[:,]? *[0-9a-f]{8,40}' | grep -oiE '[0-9a-f]{8,40}' | tail -1 | tr 'A-F' 'a-f')
  keyid=$(jq -r --arg n "$name" '.rpms[] | select(.name==$n) | .gpg_key' "$LOCK")
  want_fp=$(jq -r --arg k "$keyid" '.gpg_keys[] | select(.id==$k) | (.fingerprint // "")' "$LOCK" | tr 'A-F' 'a-f')
  [ -n "$got_fp" ] || die "não foi possível extrair fingerprint/key ID de $name — $(echo "$sigout" | tail -3 | tr '\n' ' ')"
  if [ -n "$want_fp" ]; then
    # Sufixo cobre os dois formatos: a fingerprint pinada termina no key ID curto.
    case "$want_fp" in *"$got_fp") : ;; *) die "chave difere do lock em $name: efetiva=$got_fp esperada=$want_fp" ;; esac
    note "rpm ok: $name (assinado pela chave pinada ${want_fp:0:16}…)"
  else
    # Chave sem pin de rede: procede da imagem FCOS pinada por digest.
    note "rpm ok: $name (chave da imagem pinada; fingerprint efetiva=$got_fp)"
  fi
done < <(jq -r '.rpms[] | [.name, .url, .sha256] | @tsv' "$LOCK")

note "verify-lock: TODOS os inputs conferem com o lock"
