# Only pods that are ending: failed, being deleted, deleted, or marked for disruption.
.type as $event
| .object
| select(
    $event == "DELETED"
    or .status.phase == "Failed"
    or .metadata.deletionTimestamp != null
    or ([.status.conditions[]? | select(.type == "DisruptionTarget")] | length > 0)
  )
| {
    lifecycle: $event,
    namespace: .metadata.namespace,
    pod: .metadata.name,
    uid: .metadata.uid,
    node: .spec.nodeName,
    owner: ((.metadata.ownerReferences // [])[0] | if . then "\(.kind)/\(.name)" else null end),
    phase: .status.phase,
    reason: .status.reason,
    message: .status.message,
    deleting: (.metadata.deletionTimestamp != null),
    disruption: ([.status.conditions[]? | select(.type == "DisruptionTarget")
                  | {reason, message, at: .lastTransitionTime}] | first),
    containers: [.status.containerStatuses[]?
                 | select(.state.terminated)
                 | {name, exitCode: .state.terminated.exitCode,
                    reason: .state.terminated.reason,
                    lastLines: (.state.terminated.message // "" | split("\n") | map(select(length > 0)) | .[-10:])}]
  }
