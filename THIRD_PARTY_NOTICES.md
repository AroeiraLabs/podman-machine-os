# Third-party notices — Acai P4-3A

This repository adds no executable payload and distributes no generated image.

| Component | Revision | License evidence | Notice status |
| --- | --- | --- | --- |
| `podman-machine-os` | `80b13071a9695a84ccbc311e33785b31209102f4` (tag `v6.0.2`) | root `LICENSE` (Apache License 2.0) | no root `NOTICE` at this revision |
| `custom-coreos-disk-images` | `e017ddda3b20b09627f90f68ef1b708016d10864` | submodule `LICENSE` (GNU GPL v3) | no `NOTICE` at this revision |

Locked binary inputs (RPMs from Fedora 44 GA/updates and the two COPR
projects, plus the pinned OCI base images) are enumerated with immutable
identities in [`acai/lock.json`](acai/lock.json). Their per-component license
inventory is deliberately not asserted here: it belongs to the SBOM produced
for a concrete digest. P4-3B remains blocked until the final build inputs and
SBOM establish every included component and its corresponding source/notices.
