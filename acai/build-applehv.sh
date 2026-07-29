#!/usr/bin/env bash
# Acai P4-3A — build travado, somente AppleHV/arm64, sem publicação.
# Pré-requisito: acai/verify-lock.sh executado com sucesso (mesmo job).
# A saída fica no disco efêmero do runner e é destruída ao final.
set -euo pipefail

LOCK="acai/lock.json"
WORK="${ACAI_WORK:-/var/tmp/acai}"
SRC="$WORK/src"
RPMS="$WORK/rpms"
OUT="$WORK/out"

die() { printf '::error::ACAI P4-3A STOP: %s\n' "$*"; exit 42; }
note() { printf '::notice::%s\n' "$*"; }

[ -d "$SRC/.git" ] || die "fonte não preparada — rode verify-lock antes"
mkdir -p "$OUT"

PLATFORMS=$(jq -r .target.platforms "$LOCK")
[ "$PLATFORMS" = "applehv" ] || die "seletor de target diverge do gate: $PLATFORMS"
FCOS_DIGEST=$(jq -r .oci.fcos_base.arm64_digest "$LOCK")
FCOS_REF="$(jq -r .oci.fcos_base.ref "$LOCK")@${FCOS_DIGEST}"
IMAGE_TAG="localhost/acai-podman-machine-oci:6.0-aarch64"

# Patches próprios (declarados no lock, já conferidos com --check).
while IFS= read -r p; do
  git -C "$SRC" apply "$(pwd)/$p"
  note "patch aplicado: $p"
done < <(jq -r '.source.patches[].file' "$LOCK")

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
rpm-ostree compose build-chunked-oci \
  --bootc --from "$IMAGE_TAG" \
  --output "oci-archive:${OUT}/podman-machine.aarch64.oci"

pushd "$OUT" >/dev/null
sh "$SRC"/custom-coreos-disk-images/custom-coreos-disk-images.sh \
  --platforms "$PLATFORMS" \
  --ociarchive "${PWD}/podman-machine.aarch64.oci" \
  --osname fedora-coreos \
  --imgref "ostree-unverified-registry:${IMAGE_TAG}" \
  --metal-image-size 6144 \
  --extra-kargs='ostree.prepare-root.composefs=0'
popd >/dev/null

# ---------- relatório sanitizado + destruição da saída ----------
RAW=$(find "$OUT" -name "*applehv*" -type f | head -1)
[ -n "$RAW" ] || die "nenhuma saída applehv produzida"
EXTRA=$(find "$OUT" -type f -name "*-hyperv*" -o -type f -name "*-qemu*" | wc -l | tr -d ' ')
[ "$EXTRA" = "0" ] || die "targets além de applehv foram produzidos"
note "saída applehv: $(basename "$RAW") | bytes=$(stat -c%s "$RAW") | sha256=$(sha256sum "$RAW" | cut -d' ' -f1)"
note "manifesto de RPMs da imagem (registro, não autorização):"
podman run --rm --cgroups=disabled "$IMAGE_TAG" rpm -qa --qf '%{NEVRA}\n' | sort | head -400

rm -rf "$OUT"
podman rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
note "saída destruída — nenhum artefato persistido, nenhuma publicação"
