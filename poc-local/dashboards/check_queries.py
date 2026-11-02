"""Runs every query of every dashboard through Grafana and reports any that fail.

Usage: python dashboards/check_queries.py http://127.0.0.1:23031 admin <password>

Dashboard variables are replaced with their "All" or default values, as a viewer opening the
dashboard would see them. A query that errors fails the check; a query that runs but returns
nothing is listed, since some panels stay empty until something happens (an OOM kill, say).
"""
import base64
import glob
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
grafana, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
AUTH = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

DEFAULTS = {"$cluster": "poc", "$__range": "1h", "$__auto": "1m", "$service": "demo-checkout"}


def substitute(text, variables):
    # Longest names first, so $__range is not cut short by a shorter variable.
    for name in sorted(variables, key=len, reverse=True):
        text = text.replace(name, variables[name])
    return text


def variables_of(board):
    values = dict(DEFAULTS)
    for v in board["templating"]["list"]:
        if v["name"] == "cluster":
            continue
        if v.get("includeAll"):
            values["$" + v["name"]] = v.get("allValue", ".+")
        else:
            values["$" + v["name"]] = v.get("query", "")
    return values


def run(query):
    body = json.dumps({"queries": [query], "from": "now-1h", "to": "now"}).encode()
    req = urllib.request.Request(f"{grafana}/api/ds/query", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": AUTH})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.load(resp)["results"]["A"]
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}", False
    if result.get("error"):
        return result["error"], []
    return None, result.get("frames", [])


def row_count(frames):
    return sum(len(f["data"]["values"][0]) if f.get("data", {}).get("values") else 0 for f in frames)


def event_names_shown(frames):
    """Counts (lines checked, lines missing the object's name) in an events panel's output.

    The collector moves the object's name out of the line into the `object` metadata, so a
    template reading it from the JSON body runs without an error but prints a blank.
    """
    checked = missing = 0
    for frame in frames:
        fields = [f["name"] for f in frame["schema"]["fields"]]
        if "labels" not in fields or "Line" not in fields:
            continue
        values = frame["data"]["values"]
        for labels, line in zip(values[fields.index("labels")], values[fields.index("Line")]):
            name = labels.get("object")
            if name:
                checked += 1
                missing += name not in line
    return checked, missing


failed, empty, total, event_lines = [], [], 0, 0
for path in sorted(glob.glob(os.path.join(HERE, "*.json"))):
    board = json.load(open(path, encoding="utf-8"))
    values = variables_of(board)
    for panel in board["panels"]:
        for t in panel.get("targets", []):
            total += 1
            q = dict(t, refId="A", intervalMs=60000, maxDataPoints=500, maxLines=100)
            for key in ("expr", "query"):
                if key in q:
                    q[key] = substitute(q[key], values)
            error, frames = run(q)
            where = f'{board["title"]} / {panel["title"]}'
            if len(panel["targets"]) > 1:
                where += f' (query {t["refId"]})'
            if error:
                failed.append(f"{where}: {error}")
            elif not row_count(frames):
                empty.append(where)
            elif 'job="kubernetes-events"' in q.get("expr", "") and "line_format" in q["expr"]:
                checked, missing = event_names_shown(frames)
                event_lines += checked
                if missing:
                    failed.append(f"{where}: {missing} of {checked} lines do not show the object's name")

print(f"{total - len(failed)} of {total} panel queries ran without errors")
print(f"  {event_lines} event lines checked for the object's name")
for f in failed:
    print("  ERROR  " + f)
for e in empty:
    print("  empty  " + e)
sys.exit(1 if failed else 0)
