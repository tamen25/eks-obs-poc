"""Turn on API server audit logging in the kind control plane (restarts kube-apiserver).

Copies audit-policy.yaml into the node, adds the audit flags and hostPath mounts
to the kube-apiserver static pod manifest, and waits for the API to return.
Idempotent: a manifest that already has --audit-policy-file is left alone.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

NODE = "evict-lab-control-plane"
MANIFEST = "/etc/kubernetes/manifests/kube-apiserver.yaml"
POLICY = Path(__file__).with_name("audit-policy.yaml")
ENV = dict(os.environ, MSYS_NO_PATHCONV="1")

FLAGS = [
    "--audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml",
    "--audit-log-path=/var/log/kubernetes/audit/audit.log",
    "--audit-log-maxsize=50",
    "--audit-log-maxbackup=2",
]
MOUNTS = """\
    - mountPath: /etc/kubernetes/audit
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
"""
VOLUMES = """\
  - hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
    name: audit-policy
  - hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
    name: audit-log
"""


def node(*cmd, stdin=None):
    return subprocess.run(["docker", "exec", "-i", NODE, *cmd], input=stdin, text=True,
                          capture_output=True, check=True, env=ENV).stdout


def main():
    manifest = node("cat", MANIFEST)
    if "--audit-policy-file" in manifest:
        print("audit already enabled")
        return 0
    node("mkdir", "-p", "/etc/kubernetes/audit", "/var/log/kubernetes/audit")
    node("sh", "-c", "cat > /etc/kubernetes/audit/audit-policy.yaml", stdin=POLICY.read_text())

    flags = "".join(f"    - {flag}\n" for flag in FLAGS)
    manifest = manifest.replace("    - kube-apiserver\n", "    - kube-apiserver\n" + flags, 1)
    manifest = manifest.replace("    volumeMounts:\n", "    volumeMounts:\n" + MOUNTS, 1)
    manifest = manifest.replace("  volumes:\n", "  volumes:\n" + VOLUMES, 1)
    # Write outside the manifests dir first so the kubelet never sees a half-written file.
    node("sh", "-c", f"cat > /tmp/kube-apiserver.yaml && mv /tmp/kube-apiserver.yaml {MANIFEST}",
         stdin=manifest)

    print("manifest updated; waiting for kube-apiserver to restart...")
    time.sleep(15)
    for _ in range(60):
        probe = subprocess.run(["kubectl", "--context", "kind-evict-lab", "get", "--raw", "/readyz"],
                               capture_output=True, text=True, env=ENV)
        if probe.stdout.strip() == "ok":
            print("kube-apiserver ready; audit log at /var/log/kubernetes/audit/audit.log on", NODE)
            return 0
        time.sleep(3)
    print("kube-apiserver did not become ready", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
