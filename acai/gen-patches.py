#!/usr/bin/env python3
"""Gera os patches do Acai a partir de acai/lock.json.

Motivo de existir: os patches são texto estático aplicado à árvore do upstream,
então não podem ler o lock no momento em que são aplicados. Isso obrigava a
repetir o mesmo sha256 de repomd em quatro arquivos (dois patches, o workflow e
o lock) a cada re-pin — e o repositório `updates` do Fedora muda a cada poucos
dias. Errar um dos quatro pontos produzia uma falha só no meio de um build de
vinte e cinco minutos.

Agora o lock é a única fonte: este script regenera os patches e atualiza o
workflow e os hashes dos próprios patches dentro do lock.

Uso:
    python3 acai/gen-patches.py                 # regenera e confere
    python3 acai/gen-patches.py --check         # só confere, não escreve

O upstream é baixado por commit fixado no lock; nada aqui resolve versão.
"""
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "acai", "lock.json")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "acai-machine-publish.yml")
CHECK_ONLY = "--check" in sys.argv


def die(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_upstream(commit, dest):
    """Baixa a árvore do upstream no commit fixado."""
    url = f"https://github.com/podman-container-tools/podman-machine-os/archive/{commit}.tar.gz"
    tgz = os.path.join(dest, "src.tar.gz")
    urllib.request.urlretrieve(url, tgz)
    with tarfile.open(tgz) as tf:
        tf.extractall(dest, filter="data")
    for name in os.listdir(dest):
        full = os.path.join(dest, name)
        if os.path.isdir(full) and name.startswith("podman-machine-os-"):
            return full
    die("árvore do upstream não encontrada após extração")


def repo_block(repos):
    """Bloco shell que cria os repositórios travados e confere cada repomd."""
    lines = ["rm -f /etc/yum.repos.d/*.repo"]
    for r in repos:
        lines.append(
            "printf '%s\\n' "
            f"'[{r['repo_id']}]' 'name={r['repo_id']}' 'baseurl={r['baseurl']}' "
            "'enabled=1' 'gpgcheck=1' "
            "'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary' "
            f"'metadata_expire=never' > /etc/yum.repos.d/{r['repo_id']}.repo"
        )
    lines.append("dnf makecache --refresh")
    for r in repos:
        lines.append(
            f"echo \"{r['repomd_sha256']}  "
            f"$(find /var/cache -path '*{r['repo_id']}*' -name repomd.xml | head -1)\" "
            "| sha256sum -c -"
        )
    return lines


def build_common(orig, repos, enabled):
    start = orig.index('if [[ ${PODMAN_PR_NUM} == "" ]]; then')
    end = orig.index("\nfi\n", start) + len("\nfi\n")
    body = "\n".join([
        "# ACAI P4-3A source-lock: dnf preso aos snapshots imutaveis conferidos NO",
        "# CACHE que ele consome. RPMs de containers chegam pre-verificados via",
        "# acai/verify-lock.sh.",
        *repo_block(repos),
        "shopt -s nullglob",
        "ACAI_RPMS=(/var/tmp/rpms/*.rpm)",
        'if [[ ${#ACAI_RPMS[@]} -eq 0 ]]; then echo "ACAI STOP: nenhum RPM pre-verificado"; exit 42; fi',
        f"dnf install -y --best --allowerasing --disablerepo='*' --enablerepo={enabled} \"${{ACAI_RPMS[@]}}\"",
        "# Kernel fora do upgrade: kernels sao installonly e o novo entraria AO LADO",
        "# do da base, gerando imagem com dois kernels cujo disco entra em panic.",
        f"dnf upgrade -y --disablerepo='*' --enablerepo={enabled} --exclude='kernel*'",
        'if [[ $(rpm -q kernel | wc -l) -ne 1 ]]; then echo "ACAI STOP: mais de um kernel"; rpm -q kernel; exit 42; fi',
        "",
    ])
    out = orig[:start] + body + orig[end:]
    out = out.replace(
        "dnf install -y --setopt=install_weak_deps=false \\\n    subscription-manager",
        f"dnf install -y --disablerepo='*' --enablerepo={enabled} "
        "--setopt=install_weak_deps=false \\\n    subscription-manager")
    out = out.replace(
        'dnf install -y "${PACKAGES[@]}"',
        f"dnf install -y --disablerepo='*' --enablerepo={enabled} \"${{PACKAGES[@]}}\"")
    out += (
        '\n# Imagem "golden": o machine-id tem de ficar VAZIO. Com ele populado, o\n'
        "# systemd nao reconhece primeiro boot e os presets que o Ignition grava\n"
        "# nunca viram symlink: nenhuma unidade e habilitada e o guest nunca envia\n"
        "# o sinal de prontidao.\n"
        ": > /etc/machine-id\n"
        'test ! -s /etc/machine-id || { echo "ACAI STOP: machine-id nao ficou vazio"; exit 42; }\n'
    )
    return out


def containerfile(orig, repos, enabled):
    old = "RUN dnf install -y checkpolicy policycoreutils && dnf clean all && \\\n"
    if old not in orig:
        die("linha esperada do Containerfile nao encontrada")
    new = ("RUN " + " && \\\n    ".join(repo_block(repos)) + " && \\\n"
           f"    dnf install -y --disablerepo='*' --enablerepo={enabled} "
           "checkpolicy policycoreutils && dnf clean all && \\\n")
    out = orig.replace(old, new)
    # 'ostree container commit' e extensao externa (pacote bootc), ausente nesta
    # arvore, e hoje apenas esvazia diretorios que o build_common.sh ja limpa.
    out = out.replace("    /run/build_common.sh && ostree container commit\n",
                      "    /run/build_common.sh\n")
    return out


def main():
    lock = json.load(open(LOCK))
    repos = lock["dnf"]["repos"]
    enabled = ",".join(r["repo_id"] for r in repos)
    commit = lock["source"]["commit"]

    with tempfile.TemporaryDirectory() as tmp:
        tree = fetch_upstream(commit, tmp)
        targets = {
            "acai/patches/0001-locked-build-common.patch":
                ("podman-image/build_common.sh", build_common),
            "acai/patches/0002-locked-containerfile.patch":
                ("podman-image/Containerfile.COREOS", containerfile),
        }
        results = {}
        for patch_rel, (src_rel, fn) in targets.items():
            orig_path = os.path.join(tree, src_rel)
            orig = open(orig_path).read()
            new = fn(orig, repos, enabled)

            a_dir, b_dir = os.path.join(tmp, "a"), os.path.join(tmp, "b")
            for d in (a_dir, b_dir):
                os.makedirs(os.path.join(d, os.path.dirname(src_rel)), exist_ok=True)
            open(os.path.join(a_dir, src_rel), "w").write(orig)
            open(os.path.join(b_dir, src_rel), "w").write(new)
            diff = subprocess.run(
                ["diff", "-u", f"a/{src_rel}", f"b/{src_rel}"],
                cwd=tmp, capture_output=True, text=True).stdout
            # Cabecalhos sem timestamp, para o patch ser estavel entre execucoes.
            lines = diff.splitlines(keepends=True)
            lines[0] = f"--- a/{src_rel}\n"
            lines[1] = f"+++ b/{src_rel}\n"
            diff = "".join(lines)

            out_path = os.path.join(ROOT, patch_rel)
            if CHECK_ONLY:
                atual = open(out_path).read() if os.path.exists(out_path) else ""
                if atual != diff:
                    die(f"{patch_rel} esta desatualizado em relacao ao lock")
            else:
                open(out_path, "w").write(diff)
            results[patch_rel] = hashlib.sha256(diff.encode()).hexdigest()

            # O patch tem de aplicar limpo na arvore fixada.
            check = subprocess.run(["patch", "-p1", "--dry-run", "-i", out_path],
                                   cwd=tree, capture_output=True, text=True)
            if check.returncode != 0:
                die(f"{patch_rel} nao aplica limpo:\n{check.stdout}{check.stderr}")

    # Workflow: o repomd de cada repo tem de bater com o lock.
    wf = open(WORKFLOW).read()
    for r in repos:
        if r["repomd_sha256"] not in wf:
            if CHECK_ONLY:
                die(f"workflow nao contem o repomd de {r['repo_id']} do lock")
            die(f"workflow precisa do repomd de {r['repo_id']}: {r['repomd_sha256']}")

    # sha256 dos patches de volta no lock.
    changed = False
    for p in lock["source"]["patches"]:
        novo = results.get(p["file"])
        if novo and p["sha256"] != novo:
            if CHECK_ONLY:
                die(f"sha256 de {p['file']} no lock esta desatualizado")
            p["sha256"] = novo
            changed = True
    if changed and not CHECK_ONLY:
        json.dump(lock, open(LOCK, "w"), indent=2, ensure_ascii=False)
        open(LOCK, "a").write("\n")

    for k, v in results.items():
        print(f"{v}  {k}")
    print("OK: patches conferem com o lock" if CHECK_ONLY else "OK: patches regenerados a partir do lock")


if __name__ == "__main__":
    main()
