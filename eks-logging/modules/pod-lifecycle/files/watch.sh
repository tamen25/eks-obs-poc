#!/bin/sh
# Prints one JSON line per terminal pod state change. The node agent ships this container's
# output like any other, so facts that only live on the pod object (and vanish when it is
# deleted) end up in Loki:
#   - the DisruptionTarget condition: the only trace of an Eviction-API eviction (drain,
#     cluster-autoscaler, Karpenter), which emits no Evicted event;
#   - status.reason and message for kubelet evictions;
#   - each container's termination message, which holds the last log lines when the
#     container uses terminationMessagePolicy: FallbackToLogsOnError.
# kubectl ends a watch at the server-side timeout, so it runs in a loop.
set -u

while true; do
  kubectl get pods --all-namespaces --watch --output-watch-events -o json \
    | jq -c --unbuffered -f /scripts/filter.jq
  sleep 1
done
