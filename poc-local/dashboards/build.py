"""Builds the POC's Grafana dashboards into this folder as JSON.

Run `python dashboards/build.py` after editing; Terraform loads the JSON files. Writing them
from one script keeps the seven dashboards consistent: the same variables, colours, layout
and wording, and a link bar to all of them on each.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LOKI = {"type": "loki", "uid": "loki"}
TEMPO = {"type": "tempo", "uid": "tempo"}
TAG = "logging-poc"

# Selectors used across dashboards. Container streams are the only ones with a container label.
C = '{cluster="$cluster", container=~".+"}'
EVENTS = '{cluster="$cluster", job="kubernetes-events"}'
# The pod-lifecycle watcher's records, parsed into fields that do not clash with stream labels.
LIFECYCLE = (
    '{cluster="$cluster", namespace="logging", container="watch"}'
    ' | json pod_name="pod", ns="namespace", lifecycle="lifecycle", phase="phase", reason="reason",'
    ' msg="message", disruption="disruption.reason", cname="containers[0].name",'
    ' creason="containers[0].reason", exit="containers[0].exitCode", last="containers[0].lastLines"'
)
ERRORISH = '|~ `(?i)\\b(error|exception|fatal|panic)\\b`'
# Node errors by content: kubelet and containerd write everything to stderr, which journald
# files at priority 6 (info), so the priority field cannot tell errors apart. kubelet error
# lines start with E and the date (E1029 ...); containerd's say level=error; the kernel's
# OOM killer says "Killed process".
NODE_ERRORS = '|~ `^E[0-9]{4} |level=error|(?i)killed process|oom-kill`'


class Board:
    def __init__(self, uid, title, description):
        self.uid, self.title, self.description = uid, title, description
        self.panels, self.vars, self.y, self.next_id = [], [], 0, 1

    def add(self, panel, w, h, x=None, newline=True):
        """Place a panel; x=None starts it at the left of a new row."""
        if x is None:
            x = 0
        panel["id"] = self.next_id
        self.next_id += 1
        panel["gridPos"] = {"x": x, "y": self.y, "w": w, "h": h}
        self.panels.append(panel)
        if newline:
            self.y += h
        return panel

    def row_of(self, panels, h):
        """Panels side by side, sharing the width equally."""
        w = 24 // len(panels)
        for i, p in enumerate(panels):
            self.add(p, w, h, x=i * w, newline=i == len(panels) - 1)

    def json(self):
        return {
            "uid": self.uid,
            "title": self.title,
            "description": self.description,
            "tags": [TAG],
            "timezone": "browser",
            "editable": True,
            "graphTooltip": 1,
            "time": {"from": "now-1h", "to": "now"},
            "refresh": "30s",
            "schemaVersion": 39,
            "links": [{"type": "dashboards", "tags": [TAG], "asDropdown": False,
                       "includeVars": False, "keepTime": True, "title": "Dashboards"}],
            "templating": {"list": self.vars},
            "panels": self.panels,
        }


# Variables ---------------------------------------------------------------------------------

def var_cluster():
    return {"name": "cluster", "label": "Cluster", "type": "query", "datasource": LOKI,
            "query": {"type": 1, "label": "cluster", "stream": "", "refId": "cluster"},
            "definition": "label_values(cluster)", "refresh": 2, "sort": 1}


def var_label(name, label, stream):
    return {"name": name, "label": label, "type": "query", "datasource": LOKI,
            "query": {"type": 1, "label": name, "stream": stream, "refId": name},
            "definition": f"label_values({stream}, {name})", "refresh": 2, "sort": 1,
            "multi": True, "includeAll": True, "allValue": ".+",
            "current": {"text": "All", "value": "$__all"}}


def var_text(name, label, default=""):
    return {"name": name, "label": label, "type": "textbox", "query": default,
            "current": {"text": default, "value": default}}


def var_custom(name, label, options):
    return {"name": name, "label": label, "type": "custom", "query": ",".join(options),
            "includeAll": True, "allValue": ".+", "multi": False,
            "current": {"text": "All", "value": "$__all"}}


# Panels ------------------------------------------------------------------------------------

def text(content, title=""):
    return {"type": "text", "title": title, "options": {"mode": "markdown", "content": content}}


def target(expr, legend="", instant=False, ref="A"):
    t = {"refId": ref, "datasource": LOKI, "expr": expr, "legendFormat": legend,
         "queryType": "instant" if instant else "range"}
    return t


def stat(title, expr, description, unit="short", color="blue", thresholds=None):
    steps = thresholds or [{"color": color, "value": None}]
    return {"type": "stat", "title": title, "description": description, "datasource": LOKI,
            "targets": [target(expr, instant=True)],
            "fieldConfig": {"defaults": {"unit": unit, "noValue": "0", "decimals": 0,
                                         "color": {"mode": "thresholds"},
                                         "thresholds": {"mode": "absolute", "steps": steps}},
                            "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": "background", "graphMode": "none", "textMode": "value",
                        "justifyMode": "center"}}


def red_above_zero():
    return [{"color": "green", "value": None}, {"color": "red", "value": 1}]


def timeseries(title, targets, description, unit="short", stacked=True, bars=True):
    return {"type": "timeseries", "title": title, "description": description, "datasource": LOKI,
            "targets": targets,
            "fieldConfig": {"defaults": {
                "unit": unit,
                "custom": {"drawStyle": "bars" if bars else "line", "fillOpacity": 70 if bars else 15,
                           "lineWidth": 1, "stacking": {"mode": "normal" if stacked else "none"},
                           "showPoints": "never"},
                "color": {"mode": "palette-classic"}}, "overrides": []},
            "options": {"legend": {"displayMode": "table", "placement": "right",
                                   "calcs": ["sum"], "sortBy": "Total", "sortDesc": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}}}


def bargauge(title, expr, legend, description, unit="short", thresholds=None, max_value=None):
    defaults = {"unit": unit, "min": 0, "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute",
                               "steps": thresholds or [{"color": "blue", "value": None}]}}
    if max_value is not None:
        defaults["max"] = max_value
    return {"type": "bargauge", "title": title, "description": description, "datasource": LOKI,
            "targets": [target(expr, legend, instant=True)],
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True,
                        "valueMode": "color", "namePlacement": "left", "sizing": "auto",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}}


def logs(title, expr, description):
    return {"type": "logs", "title": title, "description": description, "datasource": LOKI,
            "targets": [target(expr)],
            "options": {"showTime": True, "wrapLogMessage": True, "enableLogDetails": True,
                        "sortOrder": "Descending", "prettifyLogMessage": False, "dedupStrategy": "none"}}


def traces_table(title, traceql, description):
    return {"type": "table", "title": title, "description": description, "datasource": TEMPO,
            "targets": [{"refId": "A", "datasource": TEMPO, "queryType": "traceql",
                         "query": traceql, "limit": 20, "tableType": "traces"}],
            "options": {"showHeader": True, "cellHeight": "sm"},
            "fieldConfig": {"defaults": {}, "overrides": []}}


# Dashboards --------------------------------------------------------------------------------

def overview():
    b = Board("poc-overview", "1 · Overview (start here)",
              "What is collected, how much, and where to look next.")
    b.vars = [var_cluster()]
    b.add(text(
        "### What this is\n"
        "Every container log on every node goes through **Fluent Bit** to **Loki**, together with "
        "the nodes' own logs (kubelet, containerd, kernel) and Kubernetes events. The demo service "
        "sends traces through the **OpenTelemetry collector** to **Tempo**. All of it runs in this "
        "cluster.\n\n"
        "| Dashboard | Use it to |\n|---|---|\n"
        "| [2 · Logs explorer](/d/poc-logs) | search any container's logs by namespace, pod, text |\n"
        "| [3 · Evicted and disrupted pods](/d/poc-evicted) | see why a pod died and read its last lines |\n"
        "| [4 · Node logs](/d/poc-nodes) | kubelet, containerd and kernel: OOM kills, image pulls, probes |\n"
        "| [5 · Traces and logs](/d/poc-traces) | follow a request from its trace to its logs and back |\n"
        "| [6 · Test scenarios](/d/poc-scenarios) | lines written vs lines received for each test run |\n"
        "| [7 · Pipeline health](/d/poc-pipeline) | check that every node is shipping logs |\n\n"
        "Numbers below cover the time range at the top right."), 24, 9)
    b.row_of([
        stat("Log lines", f"sum(count_over_time({C}[$__range]))",
             "Container log lines received in the time range."),
        stat("Containers logging",
             f"count(sum by (namespace, container) (count_over_time({C}[$__range])))",
             "Distinct containers (namespace + container name) that sent at least one line."),
        stat("Error-looking lines", f"sum(count_over_time({C} {ERRORISH} [$__range]))",
             "Lines containing error, exception, fatal or panic. A rough signal, not a severity field.",
             color="orange"),
        stat("Kubelet evictions", f'sum(count_over_time({{cluster="$cluster", job="kubernetes-events", reason="Evicted"}}[$__range]))',
             "Pods the kubelet evicted because the node ran short of memory or disk.",
             thresholds=red_above_zero()),
        stat("Crash-loop back-offs", f'sum(count_over_time({{cluster="$cluster", job="kubernetes-events", reason="BackOff"}}[$__range]))',
             "BackOff events: a container keeps exiting and the kubelet waits longer between restarts.",
             thresholds=red_above_zero()),
        stat("Node errors", f'sum(count_over_time({{cluster="$cluster", job="node"}} {NODE_ERRORS} [$__range]))',
             "Error lines from kubelet and containerd, and kernel OOM kills.",
             thresholds=red_above_zero()),
    ], 4)
    b.row_of([
        timeseries("Log lines per namespace",
                   [target(f"sum by (namespace) (count_over_time({C}[$__auto]))", "{{namespace}}")],
                   "How many lines each namespace wrote, per interval."),
        timeseries("Error-looking lines per namespace",
                   [target(f"sum by (namespace) (count_over_time({C} {ERRORISH} [$__auto]))", "{{namespace}}")],
                   "Lines containing error, exception, fatal or panic, per interval."),
    ], 8)
    b.row_of([
        bargauge("Noisiest containers",
                 f"topk(10, sum by (namespace, container) (count_over_time({C}[$__range])))",
                 "{{namespace}} / {{container}}", "The ten containers that wrote the most lines."),
        logs("Latest warnings (Kubernetes events)",
             f'{EVENTS} | json | type="Warning" | line_format "{{{{.reason}}}}  {{{{.kind}}}}/{{{{.object}}}} ({{{{.namespace}}}})  {{{{.message}}}}"',
             "Warning events from the API server: failed scheduling, back-offs, evictions, failed probes."),
    ], 10)
    return b


def logs_explorer():
    b = Board("poc-logs", "2 · Logs explorer", "Search any container's logs.")
    b.vars = [
        var_cluster(),
        var_label("namespace", "Namespace", '{cluster="$cluster", container=~".+"}'),
        var_label("container", "Container", '{cluster="$cluster", namespace=~"$namespace", container=~".+"}'),
        var_custom("stream", "Stream", ["stdout", "stderr"]),
        var_text("pod", "Pod contains"),
        var_text("search", "Text (regex)"),
    ]
    sel = ('{cluster="$cluster", namespace=~"$namespace", container=~"$container"}'
           ' | stream=~"$stream" | pod=~".*$pod.*" |~ "(?i)$search"')
    b.add(text(
        "Pick a namespace and container at the top, or type part of a pod name or any text "
        "(a regular expression, case-insensitive). Click a line for its labels: pod, node, "
        "stream. Lines are exactly as the container wrote them."), 24, 3)
    b.add(timeseries("Matching lines per container",
                     [target(f"sum by (namespace, container) (count_over_time({sel} [$__auto]))",
                             "{{namespace}} / {{container}}")],
                     "Lines matching the filters above, per container."), 16, 8, newline=False)
    b.add(stat("Matching lines", f"sum(count_over_time({sel} [$__range]))",
               "Lines matching the filters in the time range."), 4, 8, x=16, newline=False)
    b.add(stat("of which stderr", f'sum(count_over_time({sel} | stream="stderr" [$__range]))',
               "Matching lines the container wrote to stderr.", color="orange"), 4, 8, x=20)
    b.add(logs("Log lines", sel, "Newest first. Up to 1,000 lines; narrow the filters or time range for more."), 24, 18)
    return b


def evicted():
    b = Board("poc-evicted", "3 · Evicted and disrupted pods",
              "Why pods ended, and their last lines, even after the kubelet deleted the log files.")
    b.vars = [var_cluster(),
              var_label("namespace", "Namespace", '{cluster="$cluster", container=~".+"}'),
              var_text("pod", "Pod contains")]
    b.add(text(
        "| How a pod ends | What shows up here |\n|---|---|\n"
        "| **Kubelet eviction** (node short of memory or disk) | an `Evicted` event with the reason; the pod record says `reason=Evicted` |\n"
        "| **Eviction API** (drain, Karpenter, autoscaler) | no `Evicted` event; the pod record says `disruption=EvictionByEvictionAPI` |\n"
        "| **Preemption or taint** | `Preempted` or `TaintManagerEviction` events |\n"
        "| **Out of memory** | the container record says `OOMKilled`; the kernel line is on [4 · Node logs](/d/poc-nodes) |\n"
        "| **Crash loop** | `BackOff` events, one more after each restart |\n"
        "| **Force delete** | a `DELETED` pod record with no other reason |\n\n"
        "The logs stay in Loki after the node deletes them: type the pod name in **Pod contains** "
        "to read its last lines below."), 24, 9)
    b.row_of([
        stat("Kubelet evictions",
             'sum(count_over_time({cluster="$cluster", job="kubernetes-events", reason="Evicted", namespace=~"$namespace"}[$__range]))',
             "Evicted events: the kubelet removed a pod because the node ran short of a resource.",
             thresholds=red_above_zero()),
        stat("Eviction API",
             f'count(sum by (pod_name) (count_over_time({LIFECYCLE} | ns=~"$namespace" | disruption="EvictionByEvictionAPI" [$__range])))',
             "Pods removed through the Eviction API: drains, Karpenter, cluster autoscaler.",
             thresholds=red_above_zero()),
        stat("Out of memory",
             f'count(sum by (pod_name) (count_over_time({LIFECYCLE} | ns=~"$namespace" | creason="OOMKilled" [$__range])))',
             "Pods with a container killed for going over its memory limit.",
             thresholds=red_above_zero()),
        stat("Crash-looping pods",
             'count(sum by (object) (count_over_time({cluster="$cluster", job="kubernetes-events", reason="BackOff", namespace=~"$namespace"}[$__range])))',
             "Pods with BackOff events: a container that keeps exiting.",
             thresholds=red_above_zero()),
        stat("Preempted or tainted",
             'sum(count_over_time({cluster="$cluster", job="kubernetes-events", reason=~"Preempted|TaintManagerEviction", namespace=~"$namespace"}[$__range]))',
             "Pods the scheduler preempted for higher-priority pods, or removed by a NoExecute taint.",
             thresholds=red_above_zero()),
        stat("Pods that ended",
             f'count(sum by (pod_name) (count_over_time({LIFECYCLE} | ns=~"$namespace" | phase="Failed" or lifecycle="DELETED" [$__range])))',
             "Pods that failed or were deleted, for any reason, normal rollouts included.",
             color="purple"),
    ], 4)
    b.add(timeseries("Disruption events over time",
                     [target('sum by (reason) (count_over_time({cluster="$cluster", job="kubernetes-events", namespace=~"$namespace", reason=~"Evicted|Killing|Preempted|Preempting|TaintManagerEviction|EvictionThresholdMet|OOMKilling|BackOff"}[$__auto]))',
                             "{{reason}}")],
                     "Kubernetes events that mark a pod being stopped or failing."), 24, 8)
    b.add(logs("Why each pod ended (pod-lifecycle watcher)",
               f'{LIFECYCLE} | ns=~"$namespace" | pod_name=~".*$pod.*" | phase="Failed" or lifecycle="DELETED" or disruption!=""'
               ' | line_format "{{.ns}}/{{.pod_name}}  {{.lifecycle}}  phase={{.phase}}  reason={{.reason}}  disruption={{.disruption}}  container={{.cname}} {{.creason}} exit={{.exit}}  last lines: {{.last}}"',
               "One record per change in a pod's final moments, from a watcher on the API server. "
               "'last lines' is the container's termination message, set when it uses "
               "terminationMessagePolicy: FallbackToLogsOnError."), 24, 10)
    b.row_of([
        logs("Eviction and termination events",
             '{cluster="$cluster", job="kubernetes-events", namespace=~"$namespace", reason=~"Evicted|Killing|Preempted|Preempting|TaintManagerEviction|EvictionThresholdMet|OOMKilling|BackOff"}'
             ' | object=~".*$pod.*" | json | line_format "{{.reason}}  {{.kind}}/{{.object}}  {{.message}}"',
             "Evicted = kubelet eviction. Killing without Evicted = deleted or evicted through the API."),
        logs("Last lines of the pod",
             '{cluster="$cluster", namespace=~"$namespace", container=~".+"} | pod=~".*$pod.*"',
             "Type part of the pod name in 'Pod contains' at the top. These lines are in Loki even "
             "when the node has already deleted the pod's log files."),
    ], 12)
    return b


def nodes():
    b = Board("poc-nodes", "4 · Node logs", "kubelet, containerd and kernel messages from every node's journal.")
    b.vars = [var_cluster(),
              var_label("unit", "Unit", '{cluster="$cluster", job="node"}'),
              var_text("node", "Node contains"),
              var_text("search", "Text (regex)")]
    sel = '{cluster="$cluster", job="node", unit=~"$unit"} | node=~".*$node.*" |~ "(?i)$search"'
    b.add(text(
        "Logs that no container writes: why an image did not pull, why a volume did not mount, "
        "why a probe failed, which process the kernel killed for memory. `kubelet.service` and "
        "`containerd.service` come from systemd; `kernel` is the kernel ring buffer (EKS nodes "
        "have it; kind nodes run in containers and do not)."), 24, 3)
    b.row_of([
        stat("kubelet errors", 'sum(count_over_time({cluster="$cluster", job="node", unit="kubelet.service"} | node=~".*$node.*" |~ `^E[0-9]{4}` [$__range]))',
             "kubelet lines at error level (they start with E and the date).", thresholds=red_above_zero()),
        stat("containerd errors", 'sum(count_over_time({cluster="$cluster", job="node", unit="containerd.service"} | node=~".*$node.*" |= "level=error" [$__range]))',
             "containerd lines with level=error.", thresholds=red_above_zero()),
        stat("Kernel OOM kills", 'sum(count_over_time({cluster="$cluster", job="node", unit="kernel"} | node=~".*$node.*" |~ `(?i)killed process|oom-kill|out of memory` [$__range]))',
             "The kernel killed a process for memory.", thresholds=red_above_zero()),
        stat("Image pull failures", 'sum(count_over_time({cluster="$cluster", job="node", unit="kubelet.service"} | node=~".*$node.*" |~ `(?i)failed to pull|ErrImagePull|ImagePullBackOff` [$__range]))',
             "kubelet could not pull an image.", thresholds=red_above_zero()),
        stat("Probe failures", 'sum(count_over_time({cluster="$cluster", job="kubernetes-events", reason="Unhealthy"}[$__range]))',
             "Unhealthy events: a liveness, readiness or startup probe failed. From events, because "
             "the kubelet logs probe failures only at higher verbosity.", thresholds=red_above_zero()),
        stat("Nodes reporting", 'count(sum by (node) (count_over_time({cluster="$cluster", job="node"}[$__range])))',
             "Nodes whose journal reached Loki in the time range.", color="green"),
    ], 4)
    b.row_of([
        timeseries("Journal lines per unit and node",
                   [target(f"sum by (unit, node) (count_over_time({sel} [$__auto]))", "{{unit}} on {{node}}")],
                   "How much each node service logs."),
        timeseries("Errors per unit",
                   [target(f'sum by (unit) (count_over_time({{cluster="$cluster", job="node", unit=~"$unit"}} | node=~".*$node.*" {NODE_ERRORS} [$__auto]))', "{{unit}}")],
                   "kubelet E lines, containerd level=error and kernel OOM kills, per interval."),
    ], 8)
    problems = logs("Errors and warnings", "", "kubelet E (error) and W (warning) lines, containerd "
                    "level=error or warning, and kernel messages at priority warning or worse.")
    problems["targets"] = [
        target('{cluster="$cluster", job="node", unit="kubelet.service"} | node=~".*$node.*" |~ `^[EW][0-9]{4}`'),
        target('{cluster="$cluster", job="node", unit="containerd.service"} | node=~".*$node.*" |~ "level=(error|warning)"', ref="B"),
        target('{cluster="$cluster", job="node", unit="kernel"} | node=~".*$node.*" | priority=~"[0-4]"', ref="C"),
    ]
    b.add(problems, 24, 10)
    b.add(logs("All node logs", sel, "Everything from the selected units. Click a line for its node and priority."), 24, 12)
    return b


def traces():
    b = Board("poc-traces", "5 · Traces and logs",
              "The demo service's requests, from trace to logs and back.")
    b.vars = [var_cluster(), var_text("service", "Service", "demo-checkout")]
    demo = '{cluster="$cluster", namespace="demo"}'
    b.add(text(
        "The demo service handles a fake order every two seconds: a `checkout` span with "
        "`db.query` and `payment` inside it. About one payment in ten is declined. Each step also "
        "writes a log line with its `trace_id`.\n\n"
        "**Logs to trace:** in *Demo service logs*, click a line, then the **TraceID** link. "
        "**Trace to logs:** click a trace ID in the tables, then a span's log icon. "
        "Your own services: send OTLP to `otel-collector.observability:4317` and print "
        "`trace_id=<id>` in log lines."), 24, 5)
    b.row_of([
        stat("Orders", f'sum(count_over_time({demo} |= "order received" [$__range]))',
             "Orders the demo service handled (from its logs).", color="blue"),
        stat("Declined payments", f'sum(count_over_time({demo} |= "payment declined" [$__range]))',
             "Payments that failed; their traces carry status=error.", color="orange"),
        stat("Decline rate",
             f'sum(count_over_time({demo} |= "payment declined" [$__range])) / sum(count_over_time({demo} |= "order received" [$__range]))',
             "Declined payments as a share of orders.", unit="percentunit",
             thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.15},
                         {"color": "red", "value": 0.3}]),
    ], 4)
    b.add(timeseries("Orders and declined payments",
                     [target(f'sum(count_over_time({demo} |= "order received" [$__auto]))', "orders"),
                      target(f'sum(count_over_time({demo} |= "payment declined" [$__auto]))', "declined", ref="B")],
                     "Per interval, from the demo service's logs.", stacked=False), 24, 7)
    b.row_of([
        traces_table("Latest traces", '{resource.service.name="$service"}',
                     "Newest traces of the service. Click a trace ID to open it."),
        traces_table("Failed traces", '{resource.service.name="$service" && status=error}',
                     "Traces with a span in error: the declined payments."),
    ], 9)
    b.add(logs("Demo service logs", demo,
               "Click a line, then the TraceID link next to trace_id, to open its trace."), 24, 10)
    return b


def scenarios():
    b = Board("poc-scenarios", "6 · Test scenarios",
              "Lines written vs lines received for each run of ./run.sh scenarios.")
    b.vars = [var_cluster(), var_text("run", "Run contains")]
    # keep: only these fields become labels (line= and payload= would make every line a
    # series). logfmt with a field list is not used: on Loki 3.7 it left run= empty.
    lines = '{cluster="$cluster", namespace="scenarios"} | logfmt | keep scenario, run, expected | scenario!="" | run=~".*$run.*"'
    b.add(text(
        "`./run.sh scenarios` runs each situation below once. Every line a scenario writes says "
        "which scenario and run it belongs to and how many lines that scenario writes in total, so "
        "this dashboard can compare. **100% means every line arrived.**\n\n"
        "| Scenario | What happens |\n|---|---|\n"
        "| evict-api | evicted through the Eviction API with no grace period (like a drain) |\n"
        "| evict-kubelet | outgrows its ephemeral-storage limit; the kubelet evicts it |\n"
        "| force-delete | deleted with --grace-period=0 --force as soon as it runs |\n"
        "| short-lived | lives about a second, deleted as soon as it completes |\n"
        "| oom-kill | writes its lines, then goes over its memory limit and is OOM-killed |\n"
        "| crashloop | 4 pods that exit straight away; their first 3 attempts are counted |\n"
        "| burst | 300,000 lines, fast enough that the kubelet rotates the log file |\n"
        "| init, sidecar, stdout, stderr | the containers of one pod, one stream each |\n"
        "| long-100k, long-400k, after-long | a 100 KB line, a 400 KB line (Loki keeps the first 256 KB) and 50 lines after them |"),
        24, 13)
    b.row_of([
        bargauge("Delivered",
                 f"sum by (run, scenario) (count_over_time({lines} [$__range]))"
                 f" / max by (run, scenario) (max_over_time({lines} | unwrap expected | __error__=\"\" [$__range]))",
                 "{{scenario}} · run {{run}}", "Lines received as a share of lines written.",
                 unit="percentunit", max_value=1,
                 thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 0.9},
                             {"color": "green", "value": 1}]),
        bargauge("Lines received",
                 f"sum by (run, scenario) (count_over_time({lines} [$__range]))",
                 "{{scenario}} · run {{run}}", "How many of each scenario's lines are in Loki."),
    ], 14)
    b.add(logs("Why each scenario pod ended (pod-lifecycle watcher)",
               f'{LIFECYCLE} | ns="scenarios" | phase="Failed" or lifecycle="DELETED" or disruption!=""'
               ' | line_format "{{.pod_name}}  {{.lifecycle}}  phase={{.phase}}  reason={{.reason}}  disruption={{.disruption}}  container {{.creason}} exit={{.exit}}"',
               "Evicted, OOMKilled, EvictionByEvictionAPI, Error: one record per change."), 24, 9)
    b.row_of([
        logs("Kubernetes events in the scenarios namespace",
             '{cluster="$cluster", job="kubernetes-events", namespace="scenarios"} | json | line_format "{{.reason}}  {{.object}}  {{.message}}"',
             "Scheduling, pulls, evictions, back-offs and kills."),
        logs("Scenario lines", '{cluster="$cluster", namespace="scenarios"} |= "run=" |~ ".*$run.*"',
             "The lines themselves (long ones are cut off in the panel, not in Loki)."),
    ], 10)
    return b


def pipeline():
    b = Board("poc-pipeline", "7 · Pipeline health", "Is every node shipping logs, and is anything in the pipeline complaining?")
    b.vars = [var_cluster()]
    b.add(text(
        "Each node runs one Fluent Bit agent. If a node stops appearing in *Lines per node*, its "
        "agent is not shipping. The two log panels show complaints from the agents and from Loki, "
        "Tempo, the collector and Grafana."), 24, 3)
    b.row_of([
        stat("Nodes shipping container logs",
             f"count(sum by (node) (count_over_time({C}[5m])))",
             "Nodes that sent container lines in the last 5 minutes. Should equal the node count.",
             color="green"),
        stat("Nodes shipping journal",
             'count(sum by (node) (count_over_time({cluster="$cluster", job="node"}[5m])))',
             "Nodes whose kubelet/containerd/kernel logs arrived in the last 5 minutes.", color="green"),
        stat("Event collector",
             'sum(count_over_time({cluster="$cluster", job="kubernetes-events"}[$__range]))',
             "Kubernetes events received in the time range (0 means the collector is not shipping).",
             color="green"),
        stat("Agent warnings and errors",
             '''sum(count_over_time({cluster="$cluster", namespace="logging", container=~"fluent-bit.*"} |~ `\\[ ?(warn|error)\\]` [$__range]))''',
             "Warning and error lines in the Fluent Bit agents' own logs.",
             thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}]),
    ], 4)
    b.row_of([
        timeseries("Lines per node", [target(f"sum by (node) (count_over_time({C}[$__auto]))", "{{node}}")],
                   "Container lines each node's agent shipped, per interval.", stacked=False, bars=False),
        timeseries("Bytes per namespace", [target(f"sum by (namespace) (bytes_over_time({C}[$__auto]))", "{{namespace}}")],
                   "Log volume in bytes, per interval.", unit="bytes"),
    ], 8)
    b.row_of([
        logs("Fluent Bit warnings and errors",
             '{cluster="$cluster", namespace="logging", container=~"fluent-bit.*"} |~ `\\[ ?(warn|error)\\]`',
             "From the agents and the event collector."),
        logs("Loki, Tempo, collector and Grafana warnings and errors",
             '{cluster="$cluster", namespace="observability"} |~ `(?i)level=(warn|error)|"level":"(warn|error)"|\\t(warn|error)\\t`',
             "From the backends in the observability namespace."),
    ], 12)
    return b


def main():
    boards = {"1-overview": overview(), "2-logs": logs_explorer(), "3-evicted": evicted(),
              "4-nodes": nodes(), "5-traces": traces(), "6-scenarios": scenarios(),
              "7-pipeline": pipeline()}
    for name, board in boards.items():
        with open(os.path.join(HERE, f"{name}.json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump(board.json(), f, indent=2, ensure_ascii=False)
            f.write("\n")
    print(f"wrote {len(boards)} dashboards")


if __name__ == "__main__":
    main()
