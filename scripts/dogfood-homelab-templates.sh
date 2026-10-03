#!/usr/bin/env bash
# QEMU check of the homelab Ignition templates from a release set, used as
# published: a diskless control plane booted with homelab-control-plane.bu
# (the Butane source, which Ignition reads as is) and a diskless node booted
# with homelab-node.ign (the compiled config) plus the join passphrase the
# control plane generated and shows, passed as the bluefin-cluster.passphrase
# credential. Nothing else is configured: each node pulls its kubeadm and
# homelab sysexts from the boot server through bluefin-sysext-fetch.service,
# the control plane runs kubeadm init and applies the default homelab
# component set, and the node discovers it over mDNS and joins.
#
# Passes when both nodes are Ready, the control plane's applier finished
# (every default component rolled out; monitoring is off, and MetalLB has no
# address pool because the template leaves HOMELAB_METALLB_ADDRESSES
# commented) and a local-path PVC binds; and the add-ons the control-plane
# template enables work through the homelab Gateway (its Service's cluster
# address, by host name): Argo Workflows rejects a request without a token
# and accepts a `kubectl create token` one, the MCP server rejects one
# without a token, answers a read tool with the generated mcp-client token
# and refuses a write tool, and the KubeStellar Console is absent until
# (dummy) OAuth app files are in homelab.d, then deployed.
# A diskless node keeps /var, and so every container image, in RAM; at the
# guest sizes here kubelet would report DiskPressure and evict pods. Each
# guest therefore gets a blank XFS disk for /var (a var.mount and its
# local-fs.target want passed as credentials, not through the template):
# what a real diskless homelab node needs too.
# Needs guest internet (registry.k8s.io, quay.io, ghcr.io, docker.io);
# DOGFOOD_DNS=<ip> as in dogfood-homelab-cluster.sh.
# Usage: dogfood-homelab-templates.sh <dir with the release set>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir="$(realpath "${1:?usage: $0 <dir>}")"
state="$(realpath -m "${DOGFOOD_STATE:-dist/dogfood-homelab-templates}")"
base_port="${DOGFOOD_PORT:-8781}"
link_port="${DOGFOOD_LINK_PORT:-40180}"
for f in homelab-control-plane.bu homelab-node.ign; do
    [ -f "${dir}/${f}" ] || { echo "ERROR: no ${f} in ${dir}" >&2; exit 1; }
done

rm -rf "${state}"
mkdir -p "${state}"

cat > "${state}/cp.probe" <<'EOF'
journalctl -f -n all -o cat -u bluefin-sysext-fetch.service -u kubeadm-init.service -u bluefin-homelab-apply.service -u 'bluefin-cluster-*' | sed -u 's/^/PROBE-LOG live: /' &
export KUBECONFIG=/etc/kubernetes/admin.conf
for _ in $(seq 360); do pass="$(bluefin-cluster passphrase 2>/dev/null)" && [ -n "${pass}" ] && break; sleep 5; done
# Test only: the host hands it to the node, as a person would.
echo "PROBE cp-passphrase=${pass}"
echo "PROBE cp-fetch=$(systemctl show -P Result bluefin-sysext-fetch.service) $(journalctl -b -o cat -u bluefin-sysext-fetch.service | sed -n 's/.*: merged the \(.*\) sysext(s) for .* (\(.*\))$/\1 via \2/p' | tr ' ' '-')"
echo "PROBE cp-merged=$(ls /usr/lib/extension-release.d | sed 's/^extension-release\.//' | tr '\n' ' ')"
echo "PROBE cp-features=$(cd /etc/sysupdate.d && ls -d *.feature.d | tr '\n' ' ')"
echo "PROBE cp-var=$(findmnt -no SOURCE,FSTYPE /var)"
echo "PROBE cp-conf role=$(sed -n 's/^HOMELAB_ROLE=//p' /etc/bluefin/homelab.conf) mode=$(stat -c %a /etc/bluefin/homelab.conf) set=$(grep -c '^HOMELAB_' /etc/bluefin/homelab.conf)"
ready() { kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True; }
for i in $(seq 540); do
    [ "$(ready)" -ge 2 ] && break
    [ $((i % 30)) = 0 ] && kubectl get nodes --no-headers 2>&1 | sed 's/^/PROBE-LOG nodes: /'
    sleep 5
done
echo "PROBE cp-nodes-ready=$(ready) nodes=$(kubectl get nodes --no-headers | wc -l)"
# Pods that are not (yet) all ready, with their last log lines and events.
unready() {
    kubectl get pods -A -o wide --no-headers 2>&1 | grep -vE ' ([0-9]+)/\1 +(Running|Completed) ' | sed 's/^/PROBE-LOG unready: /'
    kubectl get pods -A --no-headers 2>/dev/null | grep -vE ' ([0-9]+)/\1 +(Running|Completed) ' | while read -r ns name _; do
        kubectl -n "${ns}" logs "${name}" --all-containers --tail=4 2>&1 | cut -c1-300 | sed "s|^|PROBE-LOG ${name}: |"
        kubectl -n "${ns}" get events --field-selector "involvedObject.name=${name}" --no-headers 2>&1 | tail -n 3 | cut -c1-300 | sed "s|^|PROBE-LOG ${name} event: |"
    done
}
for i in $(seq 720); do
    case "$(systemctl show -P ActiveState bluefin-homelab-apply.service)" in active) break ;; esac
    [ $((i % 24)) = 0 ] && unready
    sleep 5
done
journalctl -b -o cat --no-pager -u bluefin-homelab-apply.service | tail -n 25 | sed 's/^/PROBE-LOG apply: /'
echo "PROBE cp-init=$(systemctl show -P ActiveState kubeadm-init.service) apply=$(systemctl show -P ActiveState bluefin-homelab-apply.service)/$(systemctl show -P Result bluefin-homelab-apply.service)"
echo "PROBE cp-namespaces=$(for ns in argocd cert-manager envoy-gateway-system local-path-storage metallb-system reloader monitoring; do kubectl get ns "${ns}" >/dev/null 2>&1 && printf '%s,' "${ns}"; done)"
echo "PROBE cp-metallb-pools=$(kubectl get ipaddresspools.metallb.io -A --no-headers 2>/dev/null | wc -l)"
cat <<'PVC' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: dogfood, namespace: default}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 16Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: dogfood, namespace: default}
spec:
  containers:
  - {name: c, image: registry.k8s.io/pause:3.10.1, volumeMounts: [{name: v, mountPath: /v}]}
  volumes: [{name: v, persistentVolumeClaim: {claimName: dogfood}}]
PVC
for _ in $(seq 60); do [ "$(kubectl get pvc dogfood -o jsonpath='{.status.phase}')" = Bound ] && break; sleep 5; done
echo "PROBE cp-pvc=$(kubectl get pvc dogfood -o jsonpath='{.status.phase}') class=$(kubectl get pvc dogfood -o jsonpath='{.spec.storageClassName}')"
kubectl get nodes -o wide --no-headers | sed 's/^/PROBE-LOG node: /'
kubectl get pods -A --no-headers | sed 's/^/PROBE-LOG pod: /'
kubectl -n envoy-gateway-system get svc --no-headers 2>&1 | sed 's/^/PROBE-LOG svc: /'
# Add-ons, through the Gateway's Service (no MetalLB pool: no external address).
gw="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=homelab -o jsonpath='{.items[0].spec.clusterIP}')"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }
for _ in $(seq 60); do [ "$(code -H 'Host: argo.home.arpa' "http://${gw}/api/v1/workflows/argo")" != 000 ] && break; sleep 5; done
argo_token="$(kubectl -n argo create token argo-server)"
echo "PROBE cp-argo ready=$(kubectl -n argo get deploy argo-server workflow-controller -o jsonpath='{.items[*].status.readyReplicas}') auth=$(kubectl -n argo get deploy argo-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'auth-mode=[a-z]*') notoken=$(code -H 'Host: argo.home.arpa' "http://${gw}/api/v1/workflows/argo") token=$(code -H 'Host: argo.home.arpa' -H "Authorization: Bearer ${argo_token}" "http://${gw}/api/v1/workflows/argo")"
mcp_token="$(kubectl -n mcp get secret mcp-client-token -o jsonpath='{.data.token}' | base64 -d)"
mcp() {
    curl -s --max-time 30 -H 'Host: mcp.home.arpa' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' "$@" "http://${gw}/mcp"
}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dogfood","version":"1"}}}'
read_call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"namespaces_list","arguments":{}}}'
write_call='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"resources_create_or_update","arguments":{"resource":"{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"dogfood-mcp\",\"namespace\":\"default\"}}"}}}'
mcp -H "Authorization: Bearer ${mcp_token}" -d "${init}" -o /dev/null
read_out="$(mcp -H "Authorization: Bearer ${mcp_token}" -d "${read_call}")"
write_out="$(mcp -H "Authorization: Bearer ${mcp_token}" -d "${write_call}")"
printf '%s\n' "${read_out}" | cut -c1-300 | sed 's/^/PROBE-LOG mcp read: /'
printf '%s\n' "${write_out}" | cut -c1-300 | sed 's/^/PROBE-LOG mcp write: /'
echo "PROBE cp-mcp ready=$(kubectl -n mcp get deploy mcp-kubernetes-mcp-server -o jsonpath='{.status.readyReplicas}') notoken=$(code -H 'Host: mcp.home.arpa' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "${init}" "http://${gw}/mcp") read=$(grep -q 'kube-system' <<<"${read_out}" && echo ok || echo fail) write=$(grep -qE '"isError":true|"error":' <<<"${write_out}" && ! kubectl -n default get configmap dogfood-mcp >/dev/null 2>&1 && echo refused || echo allowed)"
echo "PROBE cp-console-before=$(kubectl -n kubestellar-console get deploy kubestellar-console >/dev/null 2>&1 && echo deployed || echo absent)"
install -d -m 0700 /etc/bluefin/homelab.d/kubestellar-console
printf %s dummy-client-id > /etc/bluefin/homelab.d/kubestellar-console/github-client-id
printf %s dummy-client-secret > /etc/bluefin/homelab.d/kubestellar-console/github-client-secret
chmod 0600 /etc/bluefin/homelab.d/kubestellar-console/*
systemctl restart bluefin-homelab-apply.service
journalctl -b -o cat --no-pager -u bluefin-homelab-apply.service | grep -E 'kubestellar|failed' | tail -n 8 | sed 's/^/PROBE-LOG apply2: /'
echo "PROBE cp-console-after=$(kubectl -n kubestellar-console get deploy kubestellar-console -o jsonpath='{.status.readyReplicas}') apply=$(systemctl show -P Result bluefin-homelab-apply.service) secret-logged=$(journalctl -b -o cat | grep -c dummy-client-secret)"
echo "PROBE cp-unhealthy-pods=$(kubectl get pods -A --no-headers | grep -cvE ' (Running|Completed) ')"
# Release the node (until now pods may run on it), and give it time to see it.
kubectl label nodes --all --overwrite dogfood-done=true >/dev/null
sleep 60
EOF

cat > "${state}/node.probe" <<'EOF'
journalctl -f -n all -o cat -u bluefin-sysext-fetch.service -u 'bluefin-cluster-*' | sed -u 's/^/PROBE-LOG live: /' &
for _ in $(seq 600); do [ -e /var/lib/bluefin-cluster/joined ] && break; sleep 5; done
echo "PROBE node-fetch=$(systemctl show -P Result bluefin-sysext-fetch.service) merged=$(ls /usr/lib/extension-release.d | sed 's/^extension-release\.//' | tr '\n' ' ')"
echo "PROBE node-joined=$([ -e /var/lib/bluefin-cluster/joined ] && echo yes || echo no) kubelet=$(systemctl is-active kubelet.service) role=$(sed -n 's/^HOMELAB_ROLE=//p' /etc/bluefin/homelab.conf)"
k() { kubectl --kubeconfig /etc/kubernetes/kubelet.conf "$@"; }
for _ in $(seq 180); do
    [ "$(k get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
    sleep 5
done
echo "PROBE node-ready=$(k get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
# Stay up, running its share of the pods, until the control plane is done.
for _ in $(seq 720); do
    [ "$(k get node "$(hostname)" -o jsonpath='{.metadata.labels.dogfood-done}' 2>/dev/null)" = true ] && break
    sleep 5
done
EOF

# One L2 segment for both guests (scripts/dogfood-lan.sh).
# shellcheck source=scripts/dogfood-lan.sh
. "${here}/dogfood-lan.sh"
lan_start "${state}" "${link_port}"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; lan_stop' EXIT

# boot <role> <port> <mem> <timeout> <mac suffix> <ignition>
boot() {
    local role=$1 creds="${state}/$1-creds"
    mkdir -p "${state}/${role}-set" "${creds}"
    for f in "${dir}"/*; do ln -sf "${f}" "${state}/${role}-set/"; done
    if [ -n "${DOGFOOD_DNS:-}" ]; then printf '%s\n' "${DOGFOOD_DNS}" > "${creds}/network.dns"; fi
    truncate -s 40G "${state}/${role}-var.raw"
    mkfs.xfs -q -L bluefin-var "${state}/${role}-var.raw"
    printf '[Mount]\nWhat=/dev/disk/by-label/bluefin-var\nWhere=/var\nType=xfs\n' > "${creds}/systemd.extra-unit.var.mount"
    printf '[Unit]\nWants=var.mount\n' > "${creds}/systemd.unit-dropin.local-fs.target~var"
    DOGFOOD_PORT="$2" DOGFOOD_MEM="$3" DOGFOOD_TIMEOUT="$4" DOGFOOD_NET="$(nic "$5")" \
    DOGFOOD_IGNITION="$6" DOGFOOD_EXTRA_PROBE="${state}/${role}.probe" DOGFOOD_CREDS="${creds}" \
    DOGFOOD_PROBE_LOG="${state}/${role}.probe.log" DOGFOOD_STATE_DISK="${state}/${role}-var.raw" \
        bash "${here}/dogfood-diskless.sh" "${state}/${role}-set" --check > "${state}/${role}.log" 2>&1
}

echo "==> control plane from homelab-control-plane.bu (log: ${state}/cp.log)"
boot cp "${base_port}" "${DOGFOOD_CP_MEM:-8192}" 5400 21 "${dir}/homelab-control-plane.bu" & cp_pid=$!
pids+=("${cp_pid}")
pass=""
for _ in $(seq 360); do
    pass="$(grep -aoE 'PROBE cp-passphrase=[a-z-]+' "${state}/cp.probe.log" 2>/dev/null | head -n1 | cut -d= -f2)" || true
    [ -n "${pass}" ] && break
    kill -0 "${cp_pid}" 2>/dev/null || break
    sleep 5
done
[ -n "${pass}" ] || { echo "FAIL: the control plane showed no join passphrase" >&2; wait "${cp_pid}" || true; tail -n 40 "${state}/cp.log" >&2; exit 1; }
mkdir -p "${state}/node-creds"
printf '%s' "${pass}" > "${state}/node-creds/bluefin-cluster.passphrase"

echo "==> node from homelab-node.ign with the control plane's passphrase (log: ${state}/node.log)"
boot node "$((base_port + 1))" "${DOGFOOD_NODE_MEM:-4096}" 3600 22 "${dir}/homelab-node.ign" & node_pid=$!
pids+=("${node_pid}")
rc=0
wait "${node_pid}" || rc=1
wait "${cp_pid}" || rc=1
for role in cp node; do grep -aoE 'PROBE[ -].*' "${state}/${role}.log" | grep -v 'PROBE-LOG live' | sed "s/^/${role}: /" || true; done

check() { grep -aqE "$2" "${state}/$1.log" || { echo "FAIL: $1: no match for: $2" >&2; rc=1; }; }
check cp 'PROBE cp-fetch=success argo-workflows-homelab-kubeadm-kubestellar-mcp-via-origin'
check cp 'PROBE cp-merged=argo-workflows_[0-9.]+ homelab_[0-9.]+ kubeadm_[0-9.]+ kubestellar_[0-9.]+ mcp_[0-9.]+ '
check cp 'PROBE cp-features=argo-workflows\.feature\.d homelab\.feature\.d kubeadm\.feature\.d kubestellar\.feature\.d mcp\.feature\.d '
check cp 'PROBE cp-conf role=control-plane mode=600 set=1$'
check cp 'PROBE cp-init=active apply=active/success'
check cp 'PROBE cp-namespaces=argocd,cert-manager,envoy-gateway-system,local-path-storage,metallb-system,reloader,$'
check cp 'PROBE cp-metallb-pools=0'
check cp 'PROBE cp-pvc=Bound class=local-path'
check cp 'PROBE cp-nodes-ready=2 nodes=2'
check cp 'PROBE cp-argo ready=1 1 auth=auth-mode=client notoken=401 token=200$'
check cp 'PROBE cp-mcp ready=1 notoken=401 read=ok write=refused$'
check cp 'PROBE cp-console-before=absent$'
check cp 'PROBE cp-console-after=1 apply=success secret-logged=0$'
check node 'PROBE node-fetch=success merged=homelab_[0-9.]+ kubeadm_[0-9.]+ '
check node 'PROBE node-joined=yes kubelet=active role=node'
check node 'PROBE node-ready=True'
for role in cp node; do check "${role}" 'PROBE failed=0'; done
[ "${rc}" = 0 ] || exit 1
echo "PASS: control plane from homelab-control-plane.bu applied the default homelab set (monitoring off, MetalLB without a pool); node from homelab-node.ign joined with the shown passphrase; both Ready"
echo "PASS: add-ons: Argo Workflows (auth-mode=client: 401 without a token, 200 with one), MCP server (401 without a token, read ok, write refused), KubeStellar Console absent without OAuth, deployed with dummy OAuth values"
