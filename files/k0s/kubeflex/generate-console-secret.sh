#!/bin/bash
# First-boot generator for the KubeStellar console session-signing secret.
#
# The console Deployment (40-kubestellar-console.yaml) reads JWT_SECRET from
# the kubestellar-console-github-oauth Secret via secretKeyRef. This script
# creates that Secret once, with a random jwt-secret, so no usable signing key
# is committed to git (see projectbluefin/server#72). The GitHub OAuth keys
# are created empty: the console consumes them with `optional: true`, and an
# operator enabling OAuth edits the generated file with real credentials.
#
# Idempotent: the secret is generated only if the file does not already exist,
# so operator-supplied OAuth credentials and issued sessions survive re-boots.
# Run once per boot by k0s-first-boot.service, before k0s applies the
# manifests (its 02- name sorts before 40-kubestellar-console.yaml).
set -euo pipefail

manifest_dir="${KUBESTELLAR_MANIFEST_DIR:-/var/lib/k0s/manifests/kubestellar}"
secret_file="$manifest_dir/02-kubestellar-console-secret.yaml"

if [ -e "$secret_file" ]; then
  exit 0
fi

mkdir -p "$manifest_dir"
jwt_secret="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"

cat > "$secret_file" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: kubestellar-console-github-oauth
  namespace: kubestellar-console
type: Opaque
stringData:
  client-id: ""
  client-secret: ""
  jwt-secret: "$jwt_secret"
YAML

chmod 0600 "$secret_file"
