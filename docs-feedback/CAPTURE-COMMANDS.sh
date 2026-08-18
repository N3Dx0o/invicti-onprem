#!/usr/bin/env bash
# Re-run these on the lab to capture fresh screenshots for the docs feedback.
# Each block is one screenshot. Run with the platform installed and settled.
export KUBECONFIG=$HOME/.kube/config
NS=invicti
CHART=$HOME/invicti-onprem/onpremises

banner(){ printf '\n\033[1;36m===== SHOT %s: %s =====\033[0m\n' "$1" "$2"; }

banner 1 "chart default: 4 warm scanners (the undocumented bit)"
grep -n -B3 -A2 "minReplicaCount" "$CHART/charts/headless-dast/values.yaml"

banner 2 "what one scanner actually reserves (3 CPU / 7Gi, not 2/4)"
POD=$(kubectl get pods -n $NS --no-headers | awk '$1 ~ /^dast-scanner-/ {print $1; exit}')
echo "pod: $POD"
kubectl get pod -n $NS "$POD" -o jsonpath='{range .spec.containers[*]}{.name}: {.resources.requests}{"\n"}{end}'

banner 3 "requests vs actual usage on the node"
kubectl describe node | grep -A6 "Allocated resources"
echo
kubectl top node

banner 4 "scanner count and pod totals"
kubectl get scaledjob -n $NS
echo
echo "total pods: $(kubectl get pods -n $NS --no-headers | wc -l)"
kubectl get pods -n $NS --no-headers | awk '{print $3}' | sort | uniq -c

banner 5 "any pod that cannot schedule, and why"
kubectl get pods -n $NS --no-headers | awk '$3=="Pending"{print $1}' | while read -r p; do
  echo "--- $p"
  kubectl get pod -n $NS "$p" -o jsonpath='{range .status.conditions[*]}{.reason} {.message}{"\n"}{end}'
done
echo "(no output above = everything scheduled)"
