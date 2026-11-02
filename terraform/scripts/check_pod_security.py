"""Check rendered manifests against the Pod Security "restricted" profile (main rules)."""
import sys
import yaml

KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"}


def pod_spec(doc):
    kind = doc.get("kind")
    if kind == "Pod":
        return doc["spec"]
    if kind == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return doc["spec"]["template"]["spec"]


def check(doc):
    problems = []
    spec = pod_spec(doc)
    psc = spec.get("securityContext") or {}
    for flag in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(flag):
            problems.append(flag)
    for v in spec.get("volumes") or []:
        if "hostPath" in v:
            problems.append(f"hostPath volume {v['name']}")
    containers = (spec.get("initContainers") or []) + (spec.get("containers") or [])
    for c in containers:
        sc = c.get("securityContext") or {}
        name = c["name"]
        if sc.get("privileged"):
            problems.append(f"{name}: privileged")
        if sc.get("allowPrivilegeEscalation") is not False:
            problems.append(f"{name}: allowPrivilegeEscalation not false")
        drops = (sc.get("capabilities") or {}).get("drop") or []
        if "ALL" not in drops:
            problems.append(f"{name}: capabilities.drop lacks ALL")
        adds = set((sc.get("capabilities") or {}).get("add") or []) - {"NET_BIND_SERVICE"}
        if adds:
            problems.append(f"{name}: adds {sorted(adds)}")
        non_root = sc.get("runAsNonRoot", psc.get("runAsNonRoot"))
        if non_root is not True:
            problems.append(f"{name}: runAsNonRoot not true")
        if sc.get("runAsUser", psc.get("runAsUser")) == 0:
            problems.append(f"{name}: runAsUser 0")
        seccomp = (sc.get("seccompProfile") or psc.get("seccompProfile") or {}).get("type")
        if seccomp not in ("RuntimeDefault", "Localhost"):
            problems.append(f"{name}: seccompProfile missing")
    return problems


def main(paths):
    failed = False
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            for doc in yaml.safe_load_all(fh):
                if not doc or doc.get("kind") not in KINDS:
                    continue
                problems = check(doc)
                label = f"{path}: {doc['kind']}/{doc['metadata']['name']}"
                if problems:
                    failed = True
                    print(f"FAIL {label}: {'; '.join(problems)}")
                else:
                    print(f"ok   {label}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
