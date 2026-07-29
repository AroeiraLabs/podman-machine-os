# Corresponding source record — Acai P4-3A

## Status

No image, OCI archive, disk image, release asset, or GHCR package is distributed
by this repository. This document is a source-and-notices record for the locked
probe build; it is not an offer for a future artifact and does not authorize
publication.

## Fixed public source revision (locked)

The authoritative machine-readable lock is [`acai/lock.json`](acai/lock.json).
Human-readable summary:

| Component | Public repository | Repository ID | Revision | Declared license |
| --- | --- | ---: | --- | --- |
| machine image source | `podman-container-tools/podman-machine-os` | `774381571` | `80b13071a9695a84ccbc311e33785b31209102f4` (tag `v6.0.2`) | Apache-2.0 |
| disk-image converter submodule | `coreos/custom-coreos-disk-images` | `761458964` | `e017ddda3b20b09627f90f68ef1b708016d10864` | GPL-3.0 (license text: GPL v3) |

The revision is also mirrored in this fork as branch `acai/v6.0.2-base`. The
previously recorded development revision `b22d4e68…` is historical evidence
only, superseded by decision D-008/P4-3A-SL in `AroeiraLabs/acai`.

Local modifications are limited to the reviewable patch set under
[`acai/patches/`](acai/patches/) (declared in the lock with the file they apply
to) plus the Acai probe workflow, verification scripts, and this documentation.
Modified files state their changes through those patches; upstream `LICENSE`
and the submodule `LICENSE` are retained. No upstream `NOTICE` file exists at
the locked revisions.

## Locked binary inputs

Binary inputs are locked at two levels, both recorded in `acai/lock.json` and
verified fail-closed before any install:

1. **Directly enumerated objects** — the container-stack RPMs, GPG keys, OCI
   images (index digest, arm64 child digest, and their index-membership
   relation) and patches (SHA-256 each), verified by `acai/verify-lock.sh`.
2. **Frozen repository snapshot** — every remaining DNF resolution (job
   toolchain, `build_common.sh`, and the Containerfile first stage) is bound to
   the frozen Fedora 44 GA repository only: fixed host, `repomd.xml` SHA-256
   verified in the cache DNF actually consumes (after `dnf makecache`),
   `metadata_expire=never`, gpgcheck enabled, and
   `--disablerepo='*' --enablerepo=acai-f44-ga-locked` on every install. The
   resolved package set is deterministic for a fixed repomd and is recorded in
   the sanitized run report (`rpm -qa`).

The mutable `updates` repository is never enabled; individual packages taken
from it are pinned by URL + SHA-256 in the lock.

## Required record before any P4-3B publication

For the exact published digest, maintain an accessible record of all source,
patches, configuration, build/install scripts, base FCOS and RPM/OSTree
identities, source/SRPM directions, license inventory, notices, SBOM, and
provenance. The package page must direct recipients to that record without
authentication. This is the operational control for Apache-2.0 and GPL-covered
components; it is not a legal opinion. Publication remains blocked until that
record exists for a concrete digest.
