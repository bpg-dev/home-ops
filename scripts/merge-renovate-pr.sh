#!/usr/bin/env bash
# Merge one Renovate PR and verify the rollout.
#
# Usage: ./scripts/merge-renovate-pr.sh <PR number> [timeout seconds, default 600]
#
# 1. records the Helm revision of every HelmRelease the PR touches
# 2. squash-merges the PR (gh), reconciles flux-system and the touched Kustomizations
# 3. phase 1: every touched HelmRelease advanced its Helm revision and is Ready
#    phase 2: every new image tag / chart version from the diff is running in a pod
#             (or is the HelmRelease's chart revision)
#    phase 3: cluster-wide gate held for two consecutive polls: all Kustomizations and
#             HelmReleases Ready, no bad pods, touched Kustomizations applied the new sha
# Exit 0 = healthy, 1 = timeout (prints what is still pending), 2 = merge failed.
# Set IGNORE_HR='name1|name2' to exclude known-unready HelmReleases from the gate.
# Merge PRs one at a time; see CLAUDE.md "Renovate PRs".
set -u
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || exit 2
export KUBECONFIG=./kubeconfig
[ $# -ge 1 ] || { echo "usage: $0 <PR number> [timeout seconds]" >&2; exit 2; }
PR=$1; TIMEOUT=${2:-600}
TITLE=$(gh pr view "$PR" --json title --jq .title)
DIFF=$(gh pr diff "$PR")
FILES=$(echo "$DIFF" | grep -E '^\+\+\+ b/' | sed 's#^+++ b/##')
DIRS=$(echo "$FILES" | grep -E '^kubernetes/apps/' | sed -E 's#kubernetes/apps/([^/]+)/([^/]+)/.*#\1/\2#' | sort -u)
echo "### PR #$PR: $TITLE"
echo "dirs: $(echo $DIRS | tr '\n' ' ')"

# new tags introduced by the diff (image tags or chart versions)
TAGS=$(echo "$DIFF" | grep -E '^\+\s+(tag|version|image):' | sed -E 's/^\+\s+(tag|version|image):\s*//; s/^&[a-zA-Z]+ //; s/"//g; s/@sha256.*//; s/^.*://' | tr ' ' '\n' | grep -vE '^(&|$)' | sort -u)
echo "expect tags: $(echo $TAGS | tr '\n' ' ')"

# touched HelmReleases: ns/name -> pre-merge helm revision
declare -A PRE
HRS=""
for d in $DIRS; do
  ns=${d%%/*}
  for f in kubernetes/apps/$d/app/helmrelease.yaml kubernetes/apps/$d/app/*/helmrelease.yaml; do
    [ -f "$f" ] || continue
    for n in $(awk '/^kind: HelmRelease/{k=1} k&&/^metadata:/{m=1} m&&/^  name:/{print $NF; k=0; m=0}' "$f"); do
      v=$(kubectl get hr "$n" -n "$ns" -o jsonpath='{.status.history[0].version}' 2>/dev/null)
      [ -n "$v" ] || continue
      PRE["$ns/$n"]=$v; HRS="$HRS $ns/$n"
    done
  done
done
echo "touched HRs: $(for k in $HRS; do echo -n "$k(rev ${PRE[$k]}) "; done)"

if ! gh pr merge "$PR" --squash --delete-branch 2>&1; then
  echo "MERGE FAILED for #$PR"; exit 2
fi
sleep 20
SHA=$(git ls-remote origin refs/heads/main | cut -c1-7)
echo "main now at $SHA"
flux reconcile ks flux-system --with-source >/dev/null 2>&1 || flux reconcile ks flux-system --with-source

KS=""
for d in $DIRS; do
  f="kubernetes/apps/$d/ks.yaml"; [ -f "$f" ] || continue
  ns=${d%%/*}
  for n in $(awk '/^kind: Kustomization/{k=1} k&&/^metadata:/{m=1} m&&/^  name:/{print $NF; k=0; m=0}' "$f"); do KS="$KS $ns/$n"; done
done
KS=$(echo $KS | tr ' ' '\n' | sort -u)
for k in $KS; do ns=${k%%/*}; n=${k##*/}; flux reconcile ks "$n" -n "$ns" >/dev/null 2>&1 & done; wait
echo "reconciled ks: $(echo $KS | tr '\n' ' ')"
for k in $HRS; do ns=${k%%/*}; n=${k##*/}; flux reconcile hr "$n" -n "$ns" >/dev/null 2>&1 & done; wait

start=$(date +%s)
elapsed() { echo $(( $(date +%s) - start )); }

# --- phase 1: each touched HR must advance its helm revision and be Ready
if [ -n "$HRS" ]; then
  while :; do
    pending=""
    for k in $HRS; do
      ns=${k%%/*}; n=${k##*/}
      read -r v ready msg <<<"$(kubectl get hr "$n" -n "$ns" -o jsonpath='{.status.history[0].version} {.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)"
      if [ "${v:-0}" -le "${PRE[$k]}" ] || [ "$ready" != "True" ]; then pending="$pending $k(rev ${v:-?} ready=$ready $msg)"; fi
    done
    [ -z "$pending" ] && { echo "phase1 OK: helm revisions advanced ($(elapsed)s)"; break; }
    if [ "$(elapsed)" -gt "$TIMEOUT" ]; then echo "TIMEOUT phase1 waiting for HR upgrade:$pending"; exit 1; fi
    sleep 15
  done
else
  echo "no HelmRelease touched; settling 60s"; sleep 60
fi

# --- phase 2: new tags visible in running pods (or as HR chart revision)
if [ -n "$TAGS" ]; then
  while :; do
    missing=""
    imgs=$(for d in $DIRS; do kubectl get pods -n "${d%%/*}" -o jsonpath='{range .items[*]}{.spec.containers[*].image} {.spec.initContainers[*].image}{"\n"}{end}' 2>/dev/null; done)
    revs=$(for k in $HRS; do kubectl get hr "${k##*/}" -n "${k%%/*}" -o jsonpath='{.status.lastAttemptedRevision}{"\n"}' 2>/dev/null; done)
    for t in $TAGS; do
      echo "$imgs" | grep -qF -- ":$t" || echo "$revs" | grep -qF -- "$t" || missing="$missing $t"
    done
    [ -z "$missing" ] && { echo "phase2 OK: tags present ($(elapsed)s)"; break; }
    if [ "$(elapsed)" -gt "$TIMEOUT" ]; then echo "TIMEOUT phase2: tags not seen in pods/HR:$missing"; exit 1; fi
    sleep 15
  done
fi

# --- phase 3: global health gate, must hold for 2 consecutive polls
okcount=0
while :; do
  bad_ks=$(flux get ks -A --no-header 2>/dev/null | awk '$5!="True"')
  bad_hr=$(flux get hr -A --no-header 2>/dev/null | awk '$5!="True"' | grep -vE "${IGNORE_HR:-__none__}")
  bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed|Succeeded' | grep -vE 'volsync-(src|dst)-' | awk '!($4 ~ /^(Init|ContainerCreating|PodInitializing|Pending)/ && $6 ~ /^([0-9]+s|[12]m)/)')
  notready=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Running"{split($3,a,"/"); if(a[1]!=a[2] && !($6 ~ /^([0-9]+s|[12]m)/)) print}')
  terminating=$(for d in $DIRS; do kubectl get pods -n "${d%%/*}" --no-headers 2>/dev/null | awk '$4=="Terminating"'; done)
  stale=""
  for k in $KS; do
    ns=${k%%/*}; n=${k##*/}
    rev=$(kubectl get ks "$n" -n "$ns" -o jsonpath='{.status.lastAppliedRevision}' 2>/dev/null)
    [[ "$rev" == *"$SHA"* ]] || stale="$stale $k($rev)"
  done
  if [ -z "$bad_ks$bad_hr$bad_pods$notready$terminating$stale" ]; then
    okcount=$((okcount+1))
    if [ "$okcount" -ge 2 ]; then
      echo "HEALTHY after $(elapsed)s"
      for d in $DIRS; do ns=${d%%/*}; app=${d##*/}
        kubectl get pods -n "$ns" --no-headers -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,AGE:.metadata.creationTimestamp,IMG:.spec.containers[*].image' 2>/dev/null | grep -E "^$app" | sed 's/^/  pod /'
      done | sort -u
      for k in $HRS; do flux get hr "${k##*/}" -n "${k%%/*}" --no-header | awk -v k="$k" '{print "  hr", k, $2, "ready="$4, "helmrev"}'; done
      exit 0
    fi
  else
    okcount=0
    echo "waiting($(elapsed)s) ks:[$bad_ks] hr:[$bad_hr] pods:[$bad_pods$notready$terminating] stale:[$stale]" | tr '\n' ' '; echo
  fi
  if [ "$(elapsed)" -gt "$TIMEOUT" ]; then echo "TIMEOUT phase3"; echo "ks: $bad_ks"; echo "hr: $bad_hr"; echo "pods: $bad_pods$notready$terminating"; echo "stale: $stale"; exit 1; fi
  sleep 20
done
