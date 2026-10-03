"""Contracts for the homelab add-on sysexts (files/homelab/addons): Argo
Workflows, the Kubernetes MCP server and KubeStellar. Each add-on is a
directory the applier (bluefin-homelab-apply) finds under
/usr/share/bluefin/homelab/addons.d/ once its sysext is merged, with an
"addon" index file (default, runtimes) and manifests rendered offline by
scripts/render-homelab-manifests.py."""

from __future__ import annotations

import importlib.util
import re
import sys
import tomllib
from functools import cache
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
HOMELAB = ROOT / "files" / "homelab"
ADDONS = HOMELAB / "addons"
APPLIER = HOMELAB / "sysext" / "bluefin-homelab-apply"
EXAMPLE = HOMELAB / "sysext" / "homelab.conf.example"
SYSUPDATE = ROOT / "files" / "os" / "sysupdate.d"
IMAGE = ROOT / "elements" / "oci" / "bluefin-server-image.bst"
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")

# sysext -> its add-on directories with (default, runtimes).
EXPECTED = {
    "argo-workflows": {"10-argo-workflows": ("on", "kubeadm,k0s")},
    "mcp": {"20-mcp": ("on", "kubeadm,k0s")},
    "kubestellar": {
        "30-kubestellar-console": ("on", "kubeadm,k0s"),
        "31-kubestellar-full": ("off", "kubeadm,k0s"),
    },
}
ALL = {d: v for dirs in EXPECTED.values() for d, v in dirs.items()}


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


@cache
def docs(path: Path) -> list[dict]:
    return [d for d in yaml.load_all(path.read_text(), Loader=Loader) if d]


def files() -> list[Path]:
    return sorted(ADDONS.glob("*/*.yaml"))


def find(directory: str, kind: str, name: str) -> dict:
    return next(d for p in sorted((ADDONS / directory).glob("*.yaml")) for d in docs(p)
                if d["kind"] == kind and d["metadata"]["name"] == name)


def strings(node):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from ([(key, value)] if isinstance(value, str) else strings(value))
    elif isinstance(node, list):
        for value in node:
            yield from ([(None, value)] if isinstance(value, str) else strings(value))


def index(directory: str) -> tuple[str, str]:
    lines = [l for l in (ADDONS / directory / "addon").read_text().splitlines() if l.strip() and not l.startswith("#")]
    assert len(lines) == 1, lines
    default, runtimes = lines[0].split()
    return default, runtimes


def test_addon_directories_and_their_defaults() -> None:
    assert sorted(p.name for p in ADDONS.iterdir()) == sorted(ALL)
    for directory, expected in ALL.items():
        assert index(directory) == expected, directory


def test_addon_ids_do_not_collide_with_base_components() -> None:
    base = {line.split()[0].split("-", 1)[1] for line in (HOMELAB / "manifests" / "components").read_text().splitlines()
            if line.strip() and not line.startswith("#")}
    ids = [d.split("-", 1)[1] for d in ALL]
    assert len(set(ids)) == len(ids) and not base & set(ids)


def test_addon_directories_hold_only_ordered_manifests() -> None:
    for directory in ALL:
        names = sorted(p.name for p in (ADDONS / directory).iterdir())
        assert all(re.fullmatch(r"[0-9]{2}-[a-z0-9-]+\.yaml", n) or n in ("secrets", "addon") for n in names), names
        assert any(n.startswith("10-") for n in names), directory
        for path in (ADDONS / directory).glob("00-*.yaml"):
            assert {d["kind"] for d in docs(path)} == {"CustomResourceDefinition"}
        for path in (ADDONS / directory).glob("01-*.yaml"):
            assert {d["kind"] for d in docs(path)} == {"Namespace"}
        for path in (ADDONS / directory).glob("[1-9]*.yaml"):
            assert "CustomResourceDefinition" not in {d["kind"] for d in docs(path)}, path


def test_every_image_is_pinned_by_digest() -> None:
    embedded = re.compile(r"(?:docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io)/[a-z0-9._/-]+:[A-Za-z0-9._-]+(@sha256:[0-9a-f]{64})?")
    seen = 0
    for path in files():
        for doc in docs(path):
            for key, value in strings(doc):
                if key == "image":
                    seen += 1
                    assert DIGEST.search(value), f"{path.relative_to(ROOT)}: {value}"
                for match in embedded.finditer(value):
                    assert match.group(1), f"{path.relative_to(ROOT)}: {match.group(0)}"
    assert seen >= 6


def test_no_secret_material_is_vendored() -> None:
    for path in files():
        for doc in docs(path):
            assert "-----BEGIN" not in yaml.safe_dump(doc), path
            if doc["kind"] != "Secret":
                continue
            name = doc["metadata"]["name"]
            data = {**(doc.get("data") or {}), **(doc.get("stringData") or {})}
            if name == "postcreate-hooks":
                # KubeFlex's built-in PostCreateHook manifests, not a secret.
                assert set(data) == {"hooks.yaml"}
                continue
            assert not data, f"{path.relative_to(ROOT)}: Secret {name} carries {sorted(data)}"
    text = "".join(p.read_text() for p in files())
    assert "DEV_MODE" not in text, "the Console signs in with GitHub only"


def applier_inputs() -> set[str]:
    block = re.search(r"declare -A PATTERN=\((.*?)\n\)", APPLIER.read_text(), re.S).group(1)
    return set(re.findall(r"\[([A-Z0-9_]+)\]=", block))


def test_placeholders_are_applier_inputs_and_stay_strings() -> None:
    used = set()
    for path in files():
        used |= set(re.findall(r"\$\{HOMELAB_([A-Z0-9_]+)\}", path.read_text()))
        for doc in docs(path):
            for _, value in strings(doc):
                if "${HOMELAB_" in value and "\n" not in value:
                    assert f'"{value}"' in path.read_text() or f"'{value}'" in path.read_text(), value
    assert used == {"DOMAIN", "MCP_READ_ONLY", "MCP_READ_WRITE"}
    assert used <= applier_inputs()
    assert re.search(r"\[DOMAIN\]=home\.arpa", APPLIER.read_text()), "RFC 8375's home network domain"


@pytest.mark.parametrize("directory,namespace,host,service,port", [
    ("10-argo-workflows", "argo", "argo", "argo-server", 2746),
    ("20-mcp", "mcp", "mcp", "mcp-kubernetes-mcp-server", 8080),
    ("30-kubestellar-console", "kubestellar-console", "kubestellar", "kubestellar-console", 8080),
])
def test_each_ui_is_routed_through_the_homelab_gateway(directory, namespace, host, service, port) -> None:
    [route] = [d for p in (ADDONS / directory).glob("*.yaml") for d in docs(p) if d["kind"] == "HTTPRoute"]
    assert route["metadata"]["namespace"] == namespace
    assert route["spec"]["parentRefs"] == [{"name": "homelab", "namespace": "envoy-gateway-system"}]
    assert route["spec"]["hostnames"] == [f"{host}.${{HOMELAB_DOMAIN}}"]
    assert route["spec"]["rules"] == [{"backendRefs": [{"name": service, "port": port}]}]
    svc = find(directory, "Service", service)
    assert svc["metadata"]["namespace"] == namespace
    assert port in [p["port"] for p in svc["spec"]["ports"]]
    assert svc["spec"].get("type", "ClusterIP") == "ClusterIP", "exposed through the Gateway only"
    gateway = HOMELAB / "manifests" / "40-envoy-gateway" / "20-gateway.yaml"
    assert any(d["kind"] == "Gateway" and d["metadata"]["name"] == "homelab" for d in docs(gateway))


def container(directory: str, kind: str, name: str) -> dict:
    return find(directory, kind, name)["spec"]["template"]["spec"]["containers"][0]


def test_argo_workflows_server_takes_client_tokens_over_plain_http() -> None:
    server = container("10-argo-workflows", "Deployment", "argo-server")
    assert server["args"] == ["server", "--namespaced", "--auth-mode=client", "--secure=false"]
    assert server["readinessProbe"]["httpGet"]["scheme"] == "HTTP"
    assert "--namespaced" in container("10-argo-workflows", "Deployment", "workflow-controller")["args"]
    executor = find("10-argo-workflows", "ConfigMap", "workflow-controller-configmap")["data"]["executor"]
    assert re.fullmatch(r"image: quay\.io/argoproj/argoexec:v4\.1\.4@sha256:[0-9a-f]{64}\n", executor)
    # Namespace-scoped: Roles only, nothing cluster-wide but its CRDs.
    kinds = {d["kind"] for d in docs(ADDONS / "10-argo-workflows" / "10-argo-workflows.yaml")}
    assert not kinds & {"ClusterRole", "ClusterRoleBinding"}
    for rb in [d for d in docs(ADDONS / "10-argo-workflows" / "10-argo-workflows.yaml") if d["kind"] == "RoleBinding"]:
        assert all(s.get("namespace") == "argo" for s in rb["subjects"])


def mcp_config() -> str:
    return find("20-mcp", "ConfigMap", "mcp-kubernetes-mcp-server")["data"]["config.toml"]


def test_mcp_is_read_only_and_token_authenticated() -> None:
    config = tomllib.loads(mcp_config().replace("${HOMELAB_MCP_READ_ONLY}", "true"))
    assert "read_only = ${HOMELAB_MCP_READ_ONLY}\n" in mcp_config()
    assert config["require_oauth"] is True
    assert config["skip_jwt_verification"] is True and config["cluster_auth_mode"] == "passthrough"
    assert "authorization_url" not in config, "the API server validates every token"
    assert config["port"] == "8080" and config["cluster_provider_strategy"] == "in-cluster"
    assert {"group": "", "version": "v1", "kind": "Secret"} in config["denied_resources"]
    deployment = find("20-mcp", "Deployment", "mcp-kubernetes-mcp-server")
    assert deployment["metadata"]["annotations"]["reloader.stakater.com/auto"] == "true"
    assert deployment["spec"]["template"]["spec"]["containers"][0]["image"].startswith(
        "quay.io/containers/kubernetes_mcp_server:v0.0.67@sha256:")
    # The server's own account has no grant: tools run as the caller.
    kinds = {d["kind"] for p in (ADDONS / "20-mcp").glob("1*.yaml") for d in docs(p)}
    assert not kinds & {"ClusterRole", "ClusterRoleBinding", "Role", "RoleBinding"}


def test_mcp_client_token_is_generated_by_kubernetes_and_reads_only() -> None:
    token = find("20-mcp", "Secret", "mcp-client-token")
    assert token["type"] == "kubernetes.io/service-account-token"
    assert token["metadata"]["annotations"] == {"kubernetes.io/service-account.name": "mcp-client"}
    assert "data" not in token and "stringData" not in token
    view = find("20-mcp", "ClusterRoleBinding", "mcp-client-view")
    assert view["roleRef"]["name"] == "view"
    assert view["subjects"] == [{"kind": "ServiceAccount", "name": "mcp-client", "namespace": "mcp"}]
    # The write grant exists only with HOMELAB_MCP_READ_WRITE=yes (its file
    # carries that input, which the applier sets only then).
    edit = docs(ADDONS / "20-mcp" / "21-client-read-write.yaml")
    assert [d["roleRef"]["name"] for d in edit] == ["edit"]
    assert "${HOMELAB_MCP_READ_WRITE}" in (ADDONS / "20-mcp" / "21-client-read-write.yaml").read_text()
    applier = APPLIER.read_text()
    assert "[MCP_READ_WRITE]='^yes$'" in applier and "[MCP_READ_ONLY]='^(true|false)$'" in applier


def secrets(directory: str) -> list[list[str]]:
    return [l.split() for l in (ADDONS / directory / "secrets").read_text().splitlines()
            if l.strip() and not l.startswith("#")]


def test_console_waits_for_its_github_oauth_app() -> None:
    # The applier skips a component whose operator files are missing: the
    # Console is not deployed until both exist.
    d = "/etc/bluefin/homelab.d/kubestellar-console"
    assert secrets("30-kubestellar-console") == [
        ["kubestellar-console", "kubestellar-console-github-oauth",
         f"github-client-id=@file:{d}/github-client-id", f"github-client-secret=@file:{d}/github-client-secret"],
        ["kubestellar-console", "kubestellar-console-jwt", "jwt-secret=@random"],
    ]
    console = container("30-kubestellar-console", "Deployment", "kubestellar-console")
    env = {e["name"]: e for e in console["env"]}
    assert env["GITHUB_CLIENT_ID"]["valueFrom"]["secretKeyRef"] == {"name": "kubestellar-console-github-oauth", "key": "github-client-id"}
    assert env["GITHUB_CLIENT_SECRET"]["valueFrom"]["secretKeyRef"] == {"name": "kubestellar-console-github-oauth", "key": "github-client-secret"}
    assert env["JWT_SECRET"]["valueFrom"]["secretKeyRef"] == {"name": "kubestellar-console-jwt", "key": "jwt-secret"}
    assert env["FRONTEND_URL"]["value"] == "http://kubestellar.${HOMELAB_DOMAIN}"
    assert console["image"].startswith("ghcr.io/kubestellar/console:v0.3.42@sha256:")
    # Not exposed on the node; no kiosk proxy.
    pod = find("30-kubestellar-console", "Deployment", "kubestellar-console")["spec"]["template"]["spec"]
    assert not pod.get("hostNetwork") and not [p for p in console["ports"] if "hostPort" in p]
    text = "".join(p.read_text() for p in ADDONS.glob("3*/*.yaml"))
    assert "kiosk" not in text


def test_full_kubestellar_is_opt_in_with_its_own_database() -> None:
    assert index("31-kubestellar-full")[0] == "off"
    assert secrets("31-kubestellar-full") == [["kubeflex-system", "postgres-postgresql", "postgres-password=@random"]]
    db = find("31-kubestellar-full", "StatefulSet", "postgres-postgresql")
    env = {e["name"]: e for e in db["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["POSTGRES_PASSWORD"]["valueFrom"]["secretKeyRef"] == {"name": "postgres-postgresql", "key": "postgres-password"}
    assert find("31-kubestellar-full", "Deployment", "kubeflex-controller-manager")
    text = (ADDONS / "31-kubestellar-full" / "10-kubestellar-full.yaml").read_text()
    assert "install-postgresql" not in text, "KubeFlex's runtime Helm install of Postgres is replaced"


@cache
def render_module():
    spec = importlib.util.spec_from_file_location("render_homelab_addons", ROOT / "scripts" / "render-homelab-manifests.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_render_script_pins_every_addon_source() -> None:
    render = render_module()
    assert [c.directory for c in render.ADDON_COMPONENTS] == sorted(ALL)
    for comp in render.ADDON_COMPONENTS:
        assert comp.root == render.ADDONS
        assert re.fullmatch(r"[0-9a-f]{64}", comp.source.sha256), comp.directory
        if isinstance(comp.source, render.Chart):
            assert re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", comp.source.version), comp.directory
        else:
            assert re.search(r"/v[0-9.]+/", comp.source.url), comp.source.url
    hand = {p.relative_to(ADDONS).as_posix() for p in files() if not p.read_text().startswith(render.GENERATED)}
    assert hand == {
        "10-argo-workflows/20-httproute.yaml",
        "20-mcp/20-client.yaml",
        "20-mcp/21-client-read-write.yaml",
        "20-mcp/22-httproute.yaml",
        "30-kubestellar-console/20-httproute.yaml",
        "31-kubestellar-full/20-postgres.yaml",
    }


def test_applier_discovers_addons_after_the_base_set() -> None:
    code = APPLIER.read_text()
    assert "ADDONS=${HOMELAB_ADDONS:-${MANIFESTS}/addons.d}" in code
    assert code.index('done <"${MANIFESTS}/components"') < code.index('for dir in "${ADDONS}"/[0-9][0-9]-*/; do')
    # Control plane only: a node returns before anything is applied.
    assert code.index('"${HOMELAB_ROLE:-}" = node') < code.index("apply_entry \"${dir}\"")


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_each_addon_is_a_version_locked_opt_in_sysext(name: str) -> None:
    element = yaml.safe_load((ROOT / "elements" / "oci" / f"{name}-sysext.bst").read_text())
    sources = [s["path"] for s in element["sources"]]
    assert sources == ["files/homelab/addon-sysexts", *[f"files/homelab/addons/{d}" for d in EXPECTED[name]]]
    assert element["variables"]["sysext-image"] == f"{name}_%{{image-version}}"
    assert element["variables"]["sysext-architecture"] == ""
    text = (ROOT / "elements" / "oci" / f"{name}-sysext.bst").read_text()
    assert 'addons="sysext%{datadir}/bluefin/homelab/addons.d"' in text and "%{sysext-pack}" in text
    release = (HOMELAB / "addon-sysexts" / f"extension-release.{name}").read_text().splitlines()
    assert release == [f"NAME={name}", "ID=bluefin-server"]
    feature = (SYSUPDATE / f"{name}.feature").read_text()
    assert "Enabled" not in feature, "opt-in"
    transfer = next(SYSUPDATE.glob(f"[0-9][0-9]-{name}.transfer")).read_text()
    assert f"Features={name}\n" in transfer and f"MatchPattern={name}_@v.raw.zst" in transfer
    image = IMAGE.read_text()
    assert f"filename: oci/{name}-sysext.bst" in image
    assert image.count(f"/sysext/{name}/{name}_%{{image-version}}.raw.zst") == 2, "release set and USB stick"
    sbom = yaml.safe_load((ROOT / "elements" / "oci" / "bluefin-server-sbom.bst").read_text())
    assert f"oci/{name}-sysext.bst" in sbom["build-depends"]
    assert f'"{name}_${{v}}\\\\.raw\\\\.zst"' in (ROOT / "scripts" / "publish-release.sh").read_text()
    justfile = (ROOT / "Justfile").read_text()
    assert f"oci/{name}-sysext.bst" in justfile.split("validate:")[1].split("\n\n")[0]
    assert f"oci/{name}-sysext.bst" in (ROOT / ".github" / "workflows" / "reproducibility.yml").read_text()


def test_homelab_conf_documents_the_addon_keys() -> None:
    example = EXAMPLE.read_text()
    for key in ("DOMAIN", "ARGO_WORKFLOWS", "MCP_READ_WRITE", "KUBESTELLAR_FULL"):
        assert f"#HOMELAB_{key}=" in example, key
    assert "/etc/bluefin/homelab.d/kubestellar-console/github-client-id" in example
    assert "/etc/bluefin/homelab.d/kubestellar-console/github-client-secret" in example
