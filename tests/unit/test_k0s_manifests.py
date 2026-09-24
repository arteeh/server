from pathlib import Path

import os
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[2]


def test_k0s_service_unit():
    unit = ROOT / "files" / "k0s" / "sysext" / "k0scontroller.service"
    assert unit.is_file(), "k0scontroller.service missing"
    text = unit.read_text()
    assert "--disable-components=helm,autopilot" in text
    assert "--enable-worker" in text
    assert "--single" in text


def test_k0s_manifests_conf():
    conf = ROOT / "files" / "k0s" / "sysext" / "k0s-manifests.conf"
    assert conf.is_file(), "k0s-manifests.conf missing"
    text = conf.read_text()
    assert "d /var/lib/k0s/manifests 0755 root root - -" in text
    assert "C+ /var/lib/k0s/manifests/argocd - - - - /usr/share/k0s/manifests/argocd" in text
    assert "C+ /var/lib/k0s/manifests/kubestellar - - - - /usr/share/k0s/manifests/kubestellar" in text


def test_k0s_manifest_files():
    argo_yaml = ROOT / "files" / "k0s" / "manifests" / "argocd" / "install.yaml"
    assert argo_yaml.is_file(), "argocd install.yaml missing"
    assert "namespace: argocd" in argo_yaml.read_text()

    ks_dir = ROOT / "files" / "k0s" / "manifests" / "kubestellar"
    assert (ks_dir / "00-kubeflex-crds.yaml").is_file()
    assert (ks_dir / "10-kubeflex-operator.yaml").is_file()
    assert (ks_dir / "20-postgres.yaml").is_file()
    assert (ks_dir / "30-kubestellar-core.yaml").is_file()
    assert (ks_dir / "40-kubestellar-console.yaml").is_file()
    assert (ks_dir / "41-kubestellar-kiosk-proxy.yaml").is_file()
    assert (ks_dir / "42-kubestellar-console-rbac.yaml").is_file()


def test_postgres_password_not_hardcoded():
    # #98: the postgres superuser password must not be committed to git in
    # plaintext, and must not be the publicly documented kubeflex default.
    manifest = ROOT / "files" / "k0s" / "manifests" / "kubestellar" / "20-postgres.yaml"
    text = manifest.read_text()
    assert "kubeflex" not in text.lower().replace("kubeflex-system", "").replace("kubeflex-postgres", "")
    assert 'value: "kubeflex"' not in text
    assert "POSTGRESQL_PASSWORD" in text


def test_postgres_password_from_secret():
    # The StatefulSet reads the password from a Secret, not a plaintext env.
    docs = list(yaml.safe_load_all((ROOT / "files" / "k0s" / "manifests" / "kubestellar" / "20-postgres.yaml").read_text()))
    statefulset = next(d for d in docs if d and d.get("kind") == "StatefulSet")
    container = statefulset["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e for e in container["env"]}
    assert "value" not in env["POSTGRESQL_PASSWORD"]
    ref = env["POSTGRESQL_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert ref == {"name": "kubeflex-postgres", "key": "password"}


def test_k0s_first_boot_generates_postgres_secret_before_k0s():
    # The Secret must be staged before k0s applies the manifests, and the
    # generated 15- file must sort before 20-postgres.yaml.
    unit = ROOT / "files" / "os" / "systemd" / "system" / "k0s-first-boot.service"
    text = unit.read_text()
    lines = [l for l in text.splitlines() if l.startswith("ExecStart")]
    gen = next((i for i, l in enumerate(lines) if "generate-postgres-secret.sh" in l), None)
    k0s = next((i for i, l in enumerate(lines) if "k0scontroller.service" in l), None)
    assert gen is not None, "first-boot service never runs the postgres secret generator"
    assert k0s is not None, "first-boot service never starts k0scontroller"
    assert gen < k0s, "postgres secret generator must run before k0s applies manifests"


def test_generate_postgres_secret_is_idempotent(tmp_path):
    # Running the generator twice must not change an already-created password,
    # so the initialized database stays accessible across re-boots.
    script = ROOT / "files" / "k0s" / "kubeflex" / "generate-postgres-secret.sh"
    env = dict(os.environ, KUBEFLEX_MANIFEST_DIR=str(tmp_path))
    run = lambda: subprocess.run(["/bin/bash", str(script)], env=env, check=True, capture_output=True, text=True)
    run()
    secret_file = tmp_path / "15-kubeflex-postgres-secret.yaml"
    assert secret_file.is_file()
    secret = yaml.safe_load(secret_file.read_text())
    assert secret["kind"] == "Secret"
    assert secret["metadata"]["name"] == "kubeflex-postgres"
    assert secret["stringData"]["password"]
    first = secret_file.read_text()
    run()
    assert secret_file.read_text() == first, "password changed on re-run; DB would lose access"


def test_console_jwt_secret_not_hardcoded():
    # #72: the console JWT signing secret must not be committed to git. The
    # 01- manifest only creates the namespace; the Secret itself is generated
    # at first boot with a random jwt-secret.
    manifest = ROOT / "files" / "k0s" / "manifests" / "kubestellar" / "01-kubestellar-console-github-oauth.yaml"
    text = manifest.read_text()
    assert "kind: Secret" not in text
    assert "jwt-secret" not in yaml_values(text)
    docs = [d for d in yaml.safe_load_all(text) if d]
    assert [d["kind"] for d in docs] == ["Namespace"]


def yaml_values(text):
    # Collapse to non-comment lines so doc comments may still mention keys.
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def test_k0s_first_boot_generates_console_secret_before_k0s():
    unit = ROOT / "files" / "os" / "systemd" / "system" / "k0s-first-boot.service"
    lines = [l for l in unit.read_text().splitlines() if l.startswith("ExecStart")]
    gen = next((i for i, l in enumerate(lines) if "generate-console-secret.sh" in l), None)
    k0s = next((i for i, l in enumerate(lines) if "k0scontroller.service" in l), None)
    assert gen is not None, "first-boot service never runs the console secret generator"
    assert k0s is not None
    assert gen < k0s, "console secret generator must run before k0s applies manifests"


def test_generate_console_secret_is_idempotent(tmp_path):
    # Re-running must not rotate the jwt-secret (sessions would break) and
    # must not clobber operator-supplied OAuth credentials.
    script = ROOT / "files" / "k0s" / "kubeflex" / "generate-console-secret.sh"
    env = dict(os.environ, KUBESTELLAR_MANIFEST_DIR=str(tmp_path))
    run = lambda: subprocess.run(["/bin/bash", str(script)], env=env, check=True, capture_output=True, text=True)
    run()
    secret_file = tmp_path / "02-kubestellar-console-secret.yaml"
    assert secret_file.is_file()
    assert (secret_file.stat().st_mode & 0o777) == 0o600
    secret = yaml.safe_load(secret_file.read_text())
    assert secret["kind"] == "Secret"
    assert secret["metadata"]["name"] == "kubestellar-console-github-oauth"
    assert secret["metadata"]["namespace"] == "kubestellar-console"
    jwt = secret["stringData"]["jwt-secret"]
    assert len(jwt) == 64 and all(c in "0123456789abcdef" for c in jwt)
    assert secret["stringData"]["client-id"] == ""
    assert secret["stringData"]["client-secret"] == ""
    first = secret_file.read_text()
    run()
    assert secret_file.read_text() == first, "jwt-secret changed on re-run"
