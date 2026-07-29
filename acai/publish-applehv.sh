#!/usr/bin/env bash
# Acai P4-3B — montagem do manifesto OCI e push por digest para o GHCR.
# Roda APÓS acai/build-applehv.sh com ACAI_KEEP_OUT=1, no MESMO job.
# O login (GITHUB_TOKEN efêmero via stdin) é feito pelo workflow; o logout
# e a limpeza do auth.json são do passo final incondicional.
set -euo pipefail

WORK="${ACAI_WORK:-/var/tmp/acai}"
OUT="$WORK/out"
IMAGE="ghcr.io/aroeiralabs/podman-machine-os"
TAG="6.0"
FULL="$IMAGE:$TAG"

die() { printf '::error::ACAI P4-3B STOP: %s\n' "$*"; exit 42; }
note() { printf '::notice::%s\n' "$*"; }

OCI_TAR="$OUT/podman-machine"
ZST="$OUT/podman-machine.aarch64.applehv.raw.zst"
[ -f "$OCI_TAR" ] || die "oci-archive ausente — build não preservou a saída"
[ -f "$ZST" ] || die "artefato applehv ausente com o nome esperado: $(basename "$ZST")"
[ -f "$OUT/sbom.spdx.json" ] || die "SBOM ausente — gerar antes do push"

buildah manifest create --annotation "github.runid=${GITHUB_RUN_ID:-local}" "$FULL"
loaded=$(podman load -i "$OCI_TAR" | tail -1)
img_id="${loaded#Loaded image: }"
[ -n "$img_id" ] || die "não foi possível identificar a imagem carregada do oci-archive"
podman tag "$img_id" "$FULL-arm64"
# Imagem OCI: arch normalizada (arm64). Artefato de disco: arch NÃO normalizada
# (aarch64) — o podman machine compara literalmente contra "aarch64" ao procurar
# o disco (pkg/machine/ocipull/source.go). Mesma assimetria do gather.sh upstream.
buildah manifest add --arch arm64 "$FULL" "$FULL-arm64"
buildah manifest add --artifact --artifact-type="" --os=linux --arch=aarch64 \
  --annotation "disktype=applehv" "$FULL" "$ZST"

podman manifest push --all --digestfile "$OUT/digest.txt" "$FULL" "docker://$FULL"
DIGEST=$(cat "$OUT/digest.txt")
echo "$DIGEST" | grep -qE '^sha256:[0-9a-f]{64}$' || die "digest inválido após push"

note "PUBLICADO: ${IMAGE}@${DIGEST}"
note "A tag ${TAG} existe porque o podman machine 6.0.2 NÃO aceita referência por digest"
note "(bug: anexa a tag major.minor a refs canônicas). O consumo usa 'docker://${IMAGE}'"
note "sem tag — o podman anexa ${TAG} sozinho e assim mantém cache local."
note "sbom_sha256=$(sha256sum "$OUT/sbom.spdx.json" | cut -d' ' -f1)"
echo "digest=$DIGEST" >> "${GITHUB_OUTPUT:-/dev/null}"
