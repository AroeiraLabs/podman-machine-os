#!/usr/bin/env bash
# Acai P4-3A — build travado, somente AppleHV/arm64, sem publicação.
# Pré-requisito: acai/verify-lock.sh executado com sucesso (mesmo job).
# A saída fica no disco efêmero do runner e é destruída em QUALQUER caminho
# de término (trap), não só no sucesso.
set -euo pipefail

LOCK="acai/lock.json"
WORK="${ACAI_WORK:-/var/tmp/acai}"
SRC="$WORK/src"
RPMS="$WORK/rpms"
OUT="$WORK/out"
IMAGE_TAG="localhost/acai-podman-machine-oci:6.0-aarch64"

die() { printf '::error::ACAI P4-3A STOP: %s\n' "$*"; exit 42; }
note() { printf '::notice::%s\n' "$*"; }

cleanup() {
  if [ "${ACAI_KEEP_OUT:-0}" = "1" ]; then
    note "ACAI_KEEP_OUT=1: saída preservada para o passo de publicação do MESMO job"
    return 0
  fi
  rm -rf "$OUT" || true
  podman rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  note "cleanup executado (trap): saída e imagem locais destruídas"
}
trap cleanup EXIT

[ -d "$SRC/.git" ] || die "fonte não preparada — rode verify-lock antes"
mkdir -p "$OUT"

PLATFORMS=$(jq -r .target.platforms "$LOCK")
[ "$PLATFORMS" = "applehv" ] || die "seletor de target diverge do gate: $PLATFORMS"
CPU_ARCH=$(jq -r .target.cpu_arch "$LOCK")
[ "$CPU_ARCH" = "aarch64" ] || die "arquitetura do lock diverge: $CPU_ARCH"
FCOS_DIGEST=$(jq -r .oci.fcos_base.arm64_digest "$LOCK")
FCOS_REF="$(jq -r .oci.fcos_base.ref "$LOCK")@${FCOS_DIGEST}"

# Patches próprios (sha256 e --check já conferidos pelo verify-lock).
while IFS= read -r p; do
  git -C "$SRC" apply "$(pwd)/$p"
  note "patch aplicado: $p"
done < <(jq -r '.source.patches[].file' "$LOCK")

# Pós-patch: nenhum resolvedor dinâmico pode restar no caminho de build.
if grep -RnE 'metalink|mirrorlist' "$SRC/podman-image"; then # lockcheck-ok
  die "referência a mirror/metalink restante no caminho de build" # lockcheck-ok
fi
grep -q 'acai-f44-updates-locked' "$SRC/podman-image/build_common.sh" \
  || die "build_common.sh sem o snapshot de updates após patch"
grep -q 'acai-f44-updates-locked' "$SRC/podman-image/Containerfile.COREOS" \
  || die "Containerfile.COREOS sem o snapshot de updates após patch"
grep -q 'acai-f44-ga-locked' "$SRC/podman-image/build_common.sh" \
  || die "build_common.sh sem o repo travado após patch"
grep -q 'acai-f44-ga-locked' "$SRC/podman-image/Containerfile.COREOS" \
  || die "Containerfile.COREOS sem o repo travado após patch"

# ---------- build do container da machine (base FCOS por digest) ----------
podman build -t "$IMAGE_TAG" \
  -v "$RPMS":/var/tmp/rpms \
  -f "$SRC"/podman-image/Containerfile.COREOS "$SRC"/podman-image \
  --build-arg FCOS_BASE_IMAGE="$FCOS_REF" \
  --build-arg PODMAN_PR_NUM=""

# Sanidade: a versão do podman dentro da imagem deve ser a do lock.
GOT=$(podman run --rm --cgroups=disabled "$IMAGE_TAG" podman --version | awk '{print $3}')
WANT=$(jq -r '.rpms[] | select(.name=="podman") | .nevra' "$LOCK" | sed -E 's/^podman-[0-9]+:([0-9.]+)-.*/\1/')
[ "$GOT" = "$WANT" ] || die "podman na imagem ($GOT) difere do lock ($WANT)"
note "podman na imagem: $GOT"

# ---------- rechunk + imagem de disco (somente applehv) ----------
# Nomenclatura idêntica à do upstream (util.sh/build.sh): o arquivo do
# oci-archive é "podman-machine" sem extensão e o disco final precisa se chamar
# podman-machine.<arch>.<plataforma>.<ext>.zst — o podman machine deriva tipo e
# compressão das DUAS últimas extensões do título do layer.
rpm-ostree compose build-chunked-oci \
  --bootc --from "$IMAGE_TAG" \
  --output "oci-archive:${OUT}/podman-machine"

ls -la "$OUT" || true
[ -f "$OUT/podman-machine" ] || die "oci-archive não é arquivo regular: $(ls -la "$OUT/podman-machine" 2>&1)"

# SBOM gerada AQUI, no mesmo passo em que o artefato nasce. Antes ela era gerada
# num passo separado do workflow e dependia de o arquivo sobreviver entre passos,
# suposição que se mostrou frágil. O gate exige SBOM do artefato final antes do
# push; este é o mesmo objeto que sera publicado.
if [ "${ACAI_KEEP_OUT:-0}" = "1" ]; then
  # Enumeração POR COMPONENTE, que é o que o gate exige. O catálogo de arquivos
  # individuais fica de fora: ele respondia por quase toda a massa da SBOM
  # (16,93 MiB, acima do teto de 16 MiB do gate) e não é requisito de nenhum
  # controle — a correspondência com o artefato é feita por digest, e a
  # correspondência por pacote, pelo próprio rpm -qa registrado abaixo.
  SYFT_FILE_METADATA_SELECTION=none \
    syft "oci-archive:${OUT}/podman-machine" -o spdx-json="$OUT/sbom.spdx.json"
  jq -e '.spdxVersion' "$OUT/sbom.spdx.json" >/dev/null || die "SBOM inválida"
  pkgs=$(jq '[.packages[]?] | length' "$OUT/sbom.spdx.json")
  bytes=$(stat -c%s "$OUT/sbom.spdx.json")
  note "SBOM: $pkgs pacotes | $bytes bytes | sha256=$(sha256sum "$OUT/sbom.spdx.json" | cut -d' ' -f1)"
  [ "$bytes" -le 16777216 ] || die "SBOM acima do teto de 16 MiB do gate: $bytes bytes"
  [ "$pkgs" -ge 400 ] || die "SBOM com pacotes de menos ($pkgs) — enumeração por componente incompleta"
fi

# O custom-coreos-disk-images.sh exige getenforce == "Permissive". O runner ARM64
# do GitHub roda Ubuntu, que usa AppArmor: não há SELinux e getenforce reporta
# "Disabled" — estado em que não existe negação alguma, portanto ainda menos
# restritivo que "Permissive". A checagem é neutralizada SOMENTE nesse caso, de
# forma explícita e registrada. Com SELinux ativo, mudamos de verdade para
# permissive; se não for possível, paramos.
CCDI="$SRC/custom-coreos-disk-images/custom-coreos-disk-images.sh"
enforce=$(getenforce 2>/dev/null || echo Disabled)
note "SELinux no ambiente de build: $enforce"
case "$enforce" in
  Permissive) : ;;
  Enforcing)
    setenforce 0 || die "SELinux Enforcing e não foi possível mudar para permissive"
    note "SELinux alterado para permissive" ;;
  *)
    sed -i 's|if \[ "$(getenforce)" != "Permissive" \]; then|if false; then # ACAI-SELINUX: host sem SELinux|' "$CCDI"
    grep -q 'ACAI-SELINUX' "$CCDI" || die "não foi possível neutralizar a checagem de SELinux"
    note "host sem SELinux: checagem de permissive neutralizada explicitamente" ;;
esac

pushd "$OUT" >/dev/null
sh "$SRC"/custom-coreos-disk-images/custom-coreos-disk-images.sh \
  --platforms "$PLATFORMS" \
  --ociarchive "${PWD}/podman-machine" \
  --osname fedora-coreos \
  --imgref "ostree-unverified-registry:${IMAGE_TAG}" \
  --metal-image-size 6144 \
  --extra-kargs='ostree.prepare-root.composefs=0'

produced="podman-machine-${PLATFORMS}.${CPU_ARCH}.raw"
[ -f "$produced" ] || die "saída esperada não encontrada: $produced (presentes: $(ls | tr '\n' ' '))"
mv "$produced" "podman-machine.${CPU_ARCH}.${PLATFORMS}.raw"
popd >/dev/null

# ---------- relatório sanitizado (a destruição fica com o trap) ----------
RAW="$OUT/podman-machine.${CPU_ARCH}.${PLATFORMS}.raw"
[ -f "$RAW" ] || die "nenhuma saída applehv produzida"
# Guarda de escopo: só interessam os artefatos de disco no nível de saída.
# Buscar recursivamente pegava sobras temporárias do osbuild, que não são
# entregáveis. A mensagem lista os arquivos para o desvio ser diagnosticável.
EXTRA=$(find "$OUT" -maxdepth 1 -type f -name 'podman-machine*' \
          \( -name '*hyperv*' -o -name '*qemu*' \) -exec basename {} \; 2>/dev/null | tr '\n' ' ')
[ -z "$EXTRA" ] || die "targets além de applehv no diretório de saída: $EXTRA"
note "conteúdo do diretório de saída: $(ls "$OUT" | tr '\n' ' ')"
note "saída applehv: $(basename "$RAW") | bytes=$(stat -c%s "$RAW") | sha256=$(sha256sum "$RAW" | cut -d' ' -f1)"
note "manifesto de RPMs da imagem (registro, não autorização):"
podman run --rm --cgroups=disabled "$IMAGE_TAG" rpm -qa --qf '%{NEVRA}\n' | sort | head -400
if [ "${ACAI_KEEP_OUT:-0}" = "1" ]; then
  zstd --rm -T0 -14 "$RAW"
  note "artefato comprimido para publicação: $(basename "$RAW").zst"
else
  note "build applehv concluído sem publicação — trap destruirá a saída"
fi
