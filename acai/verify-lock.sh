#!/usr/bin/env bash
# Acai P4-3A — verificação fail-closed do source-lock ANTES do build.
# Tudo que o build consome é conferido aqui: fonte git, submódulo, manifests
# OCI, RPMs (sha256 + assinatura) e chaves. Qualquer divergência => exit 42.
set -euo pipefail

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

mkdir -p "$SRC" "$RPMS" "$KEYS"

# ---------- 1. Ambiente ----------
[ "$(uname -m)" = "aarch64" ] || die "runner não é aarch64: $(uname -m)"
. /etc/os-release
[ "${VERSION_ID:-}" = "$(jq -r .target.fedora_version "$LOCK")" ] \
  || die "container de build não é Fedora $(jq -r .target.fedora_version "$LOCK"): ${VERSION_ID:-?}"

# ---------- 2. Fonte git pinada ----------
COMMIT=$(jq -r .source.commit "$LOCK")
REPO_URL="https://github.com/$(jq -r .source.repo "$LOCK")"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet "$REPO_URL" "$SRC"
fi
git -C "$SRC" checkout --quiet "$COMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || die "HEAD da fonte difere do lock"

SUB_PATH=$(jq -r '.source.submodules[0].path' "$LOCK")
GITLINK=$(jq -r '.source.submodules[0].gitlink' "$LOCK")
TREE_GITLINK=$(git -C "$SRC" ls-tree HEAD "$SUB_PATH" | awk '{print $3}')
[ "$TREE_GITLINK" = "$GITLINK" ] || die "gitlink no tree ($TREE_GITLINK) difere do lock ($GITLINK)"
git -C "$SRC" submodule update --quiet --init "$SUB_PATH"
[ "$(git -C "$SRC/$SUB_PATH" rev-parse HEAD)" = "$GITLINK" ] || die "submódulo checked-out difere do gitlink"

# Patches declarados aplicam limpo (aplicação real é do build).
while IFS= read -r p; do
  git -C "$SRC" apply --check "$(pwd)/$p" || die "patch não aplica limpo: $p"
done < <(jq -r '.source.patches[].file' "$LOCK")

# ---------- 3. Manifests OCI conferem com os digests ----------
check_oci() {
  local ref="$1" digest="$2" repo path token body_sha
  repo="${ref#*/}"                       # fedora/fedora[-coreos]
  path="${ref%%/*}"                      # quay.io
  [ "$path" = "quay.io" ] || die "registry fora da allowlist: $ref"
  token=$(curl -fsS "https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull" | jq -r .token)
  body_sha=$(curl -fsS -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://quay.io/v2/${repo}/manifests/${digest}" | sha256sum | cut -d' ' -f1)
  [ "sha256:$body_sha" = "$digest" ] || die "manifesto OCI difere do digest para $ref@$digest"
  note "OCI ok: $ref@$digest"
}
for img in build_container fcos_base; do
  ref=$(jq -r ".oci.${img}.ref" "$LOCK")
  for d in index_digest arm64_digest; do
    check_oci "$ref" "$(jq -r ".oci.${img}.${d}" "$LOCK")"
  done
done

# ---------- 4. Chaves GPG pinadas ----------
while IFS=$'\t' read -r kid kurl ksha; do
  [ "$kurl" = "null" ] && continue
  curl -fsS -o "$KEYS/$kid.gpg" "$kurl"
  echo "$ksha  $KEYS/$kid.gpg" | sha256sum -c - >/dev/null || die "sha256 da chave $kid difere do lock"
  rpm --import "$KEYS/$kid.gpg"
  note "chave importada: $kid"
done < <(jq -r '.gpg_keys[] | [.id, (.url // "null"), (.sha256 // "")] | @tsv' "$LOCK")

# ---------- 5. RPMs pinados: download + sha256 + assinatura ----------
while IFS=$'\t' read -r name url sha; do
  f="$RPMS/$(basename "$url")"
  curl -fsS -o "$f" "$url"
  echo "$sha  $f" | sha256sum -c - >/dev/null || die "sha256 difere do lock: $name"
  sigout=$(rpm -Kv "$f")
  echo "$sigout" | grep -qE 'Signature, key ID .*: OK' || die "assinatura ausente/inválida: $name — $sigout"
  note "rpm ok: $name"
done < <(jq -r '.rpms[] | [.name, .url, .sha256] | @tsv' "$LOCK")

note "verify-lock: TODOS os inputs conferem com o lock"
