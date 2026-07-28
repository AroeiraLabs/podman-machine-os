# Corresponding source record — Acai P4-3A

## Status

No image, OCI archive, disk image, release asset, or GHCR package is distributed
by this branch. This document is a source-and-notices preflight record only; it
is not an offer for a future artifact and does not authorize publication.

## Fixed public source revision

| Component | Public repository | Repository ID | Revision | Declared license |
| --- | --- | ---: | --- | --- |
| machine image source | `podman-container-tools/podman-machine-os` | `774381571` | `b22d4e68cd75fea5ad476c9a6ca13b76f51288ea` | Apache-2.0 |
| disk-image converter submodule | `coreos/custom-coreos-disk-images` | `761458964` | `12f696dfec3b4f7fe3c8748433aa2627c0f97367` | GPL-3.0 (license text: GPL v3) |

The public fork must retain the upstream `LICENSE` and the submodule `LICENSE`.
No upstream `NOTICE` file was present at these two fixed revisions. Any future
modified file must state that it was changed, and any future upstream `NOTICE`
must be preserved before an artifact can be distributed.

## Publication blockers intentionally detected by P4-3A

The fixed source is **not yet a reproducible build input set**. The upstream
build still resolves mutable dependencies:

1. the GitHub workflow uses `fedora:latest` for its build container;
2. `util.sh` resolves the Fedora CoreOS base by stream tag;
3. the WSL Containerfile resolves a Fedora base from a version at build time;
4. DNF/Koji inputs are not recorded as a snapshot or immutable lock.

The P4-3A workflow stops before invoking the build while any of these conditions
remain. Resolving them requires a reviewed source-lock design and a new approval;
this branch does not substitute mutable tags with guessed digests.

## Required record before any P4-3B publication

For the exact published digest, maintain an accessible record of all source,
patches, configuration, build/install scripts, base FCOS and RPM/OSTree
identities, source/SRPM directions, license inventory, notices, SBOM, and
provenance. The package page must direct recipients to that record without
authentication. This is the operational control for Apache-2.0 and GPL-covered
components; it is not a legal opinion.
