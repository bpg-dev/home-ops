#!/usr/bin/env bash
set -euo pipefail

kubectl create secret generic onepassword-secret \
    --from-literal=1password-credentials.json="$(op read 'op://HomeInfra/home-ops credentials file/1password-credentials.json'|base64 -w 0)" \
    --from-literal=token="$(op read 'op://HomeInfra/home-ops token/credential')" \
    --dry-run=client \
    -o yaml > onepassword-secret.sops.yaml

sops --config ../../../../../.sops.yaml encrypt -i onepassword-secret.sops.yaml
