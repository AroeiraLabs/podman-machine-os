# Corresponding source — ghcr.io/aroeiralabs/podman-machine-os@sha256:cdf90b1bf414c3a35e04be9e0ba2cef4352f4e5d0f3b5e16c22c62cadeaf2d73

Published: 2026-07-30 · Run: https://github.com/AroeiraLabs/podman-machine-os/actions/runs/30571521204 · Lock: `acai/lock.json` na revisão deste commit

This record is the corresponding-source and notices dossier for the exact
digest above, published under decision D-011 (`AroeiraLabs/acai`). It is
reachable without authentication, as required by D-008.

## Source

| Component | Repository | ID | Revision | License |
| --- | --- | ---: | --- | --- |
| machine image source | `podman-container-tools/podman-machine-os` | `774381571` | `80b13071a9695a84ccbc311e33785b31209102f4` (tag `v6.0.2`) | Apache-2.0 |
| disk-image converter | `coreos/custom-coreos-disk-images` | `761458964` | `e017ddda3b20b09627f90f68ef1b708016d10864` | GPL-3.0 |

Both revisions are public. This fork mirrors the build revision as branch
`acai/v6.0.2-base`. Local modifications are the two reviewable patches in
[`acai/patches/`](../../../acai/patches/), each pinned by SHA-256 in the lock and
verified before application:

- `0001-locked-build-common.patch` — removes dynamic COPR/koji resolution;
  installs only pre-verified RPMs; binds DNF to the frozen snapshot.
- `0002-locked-containerfile.patch` — binds the Containerfile first stage to
  the same frozen snapshot.

## Binary inputs

Every directly enumerated input (RPMs of the container stack, GPG keys, OCI
base images with index and arm64 child digests) is listed with immutable
identity in [`acai/lock.json`](../../../acai/lock.json) and was verified
fail-closed by [`acai/verify-lock.sh`](../../../acai/verify-lock.sh) before
installation. Remaining DNF resolutions were bound to the frozen Fedora 44 GA
repository (`repomd.xml` SHA-256 `ad124f8125666e9059d7a8180427bdaea80f6286f71140457e5c7edd95883eee`,
verified in the DNF cache), per decision D-010.

Fedora and Fedora CoreOS sources are publicly available from the Fedora
Project; source RPMs for every binary RPM in the image are obtainable from the
same repositories and COPR projects recorded in the lock.

## SBOM, scan and attestations

- SBOM (SPDX JSON) generated with syft 1.44.0 over the final artifact:
  SHA-256 9f66c8116c060a4bdd01f01450ec041d5bf87984aa5694814218ff14d4c958ec
- Vulnerability scan: grype 0.116.1, threshold "zero critical and high".
- Attestations for this same digest: GitHub build provenance and SBOM
  attestation, verifiable with:

```
gh attestation verify oci://ghcr.io/aroeiralabs/podman-machine-os@sha256:cdf90b1bf414c3a35e04be9e0ba2cef4352f4e5d0f3b5e16c22c62cadeaf2d73 --owner AroeiraLabs
```

## Licenses and notices

See [`THIRD_PARTY_NOTICES.md`](../../../THIRD_PARTY_NOTICES.md). The full
per-component license inventory for this digest is the SBOM referenced above.

## Attestations for this digest

| Kind | Reference |
| --- | --- |
| build provenance | https://github.com/AroeiraLabs/podman-machine-os/attestations/38028745 |
| SBOM | https://github.com/AroeiraLabs/podman-machine-os/attestations/38028770 |

Both were verified independently during the publishing run with
`gh attestation verify --owner AroeiraLabs`; the run only succeeded because
that verification passed.

## Consumption note

`podman machine init --image` in Podman 6.0.2 does not accept digest
references: it appends the major.minor tag to canonical references, and the
underlying image library rejects a reference carrying both a tag and a digest.
Consume with `docker://ghcr.io/aroeiralabs/podman-machine-os` — Podman appends
the `6.0` tag itself. The tag is resolved against this digest out of band
before use; the digest above remains the approved reference.

## Superseded publication

`sha256:b25afd4a02694d897377d62d167b177bce84c6e498eae707c41759c55a39a160` was
pushed by an earlier run whose attestation step failed. It carries no
attestation and is **not eligible** for use under the P4-3B gate.
