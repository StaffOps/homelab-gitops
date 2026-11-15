#!/usr/bin/env python3
"""Run every Prometheus query of Grafana dashboard JSON files against a live Prometheus.

Template variables are resolved the way Grafana does (label_values, query_result, plain queries with a regex,
custom/interval/constant/textbox, chained variables), $__rate_interval & co. get fixed values, then each panel
target runs as an instant query. Prints one line per target that is EMPTY or ERROR, then a summary per file.

  kubectl --context k8s01 -n monitoring port-forward svc/kps-prometheus 19090:9090 &
  scripts/check-dashboard.py [--prometheus http://localhost:19090] [--all] dashboard.json [...]

--all also prints the targets that return data. Exit code 1 when any query errors (EMPTY is reported, not failed:
an error-rate panel is legitimately empty while nothing fails). Loki/Tempo targets are listed as skipped.
"""
import argparse, json, re, sys, urllib.error, urllib.parse, urllib.request

BUILTIN = {"__rate_interval": "5m", "__interval": "1m", "__range": "1h", "__range_s": "3600",
           "__interval_ms": "60000", "__auto_interval": "1m", "__auto": "1m", "__all": ".*"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prometheus", default="http://localhost:19090")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    P = a.prometheus.rstrip("/")

    def api(path, **params):
        u = P + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
        try:
            return json.load(urllib.request.urlopen(u, timeout=60)), None
        except urllib.error.HTTPError as e:
            try:
                return None, json.load(e).get("error", str(e))
            except Exception:
                return None, str(e)
        except Exception as e:
            return None, str(e)

    def subst(expr, vals):
        def rep(m):
            name = m.group(1) or m.group(2) or m.group(3)
            return vals.get(name, BUILTIN.get(name, m.group(0)))
        return re.sub(r'\$\{(\w+)(?::\w+)?\}|\[\[(\w+)\]\]|\$(\w+)', rep, expr)

    def panels(ps):
        for p in ps or []:
            yield p
            yield from panels(p.get("panels"))

    errors = 0
    for path in a.files:
        db = json.load(open(path))
        db = db.get("dashboard", db)
        tmpl = (db.get("templating") or {}).get("list", [])
        dsvars = {v["name"]: v.get("query") for v in tmpl if v.get("type") == "datasource"}

        def dstype(x):
            if isinstance(x, dict):
                t, u = x.get("type"), x.get("uid")
                if isinstance(u, str) and u.startswith("$"):
                    return dsvars.get(u.strip("${}"), t or "prometheus")
                return t or ("prometheus" if u in (None, "prometheus") else u)
            if x is None:
                return "prometheus"
            if isinstance(x, str) and x.startswith("$"):
                return dsvars.get(x.strip("${}"), "prometheus")
            return {"Prometheus": "prometheus", "Loki": "loki", "Tempo": "tempo", "loki": "loki",
                    "tempo": "tempo"}.get(x, "prometheus" if x in ("prometheus", "default") else x)

        vals, novals = {}, []
        for v in tmpl:
            n, t = v.get("name"), v.get("type")
            if t == "datasource":
                vals[n] = v.get("query")
                continue
            if t in ("custom", "interval", "constant", "textbox"):
                cur = (v.get("current") or {}).get("value")
                if isinstance(cur, list):
                    cur = cur[0] if cur else ""
                if cur in (None, "", "$__all"):
                    opts = v.get("options") or []
                    cur = opts[0]["value"] if opts else str(v.get("query") or "").split(",")[0]
                vals[n] = str(cur)
                continue
            if t != "query":
                continue
            q = v.get("query")
            q = q.get("query") if isinstance(q, dict) else q
            q = subst((q or "").strip(), vals)
            choices = []
            if dstype(v.get("datasource")) == "prometheus" and q:
                m = re.match(r'^label_values\((.*),\s*([\w.]+)\s*\)$', q, re.S)
                m1 = re.match(r'^label_values\(\s*([\w.]+)\s*\)$', q)
                if m:
                    j, _ = api("/api/v1/series", **{"match[]": m.group(1)})
                    choices = sorted({s.get(m.group(2)) for s in (j or {}).get("data", []) if s.get(m.group(2))})
                elif m1:
                    j, _ = api(f"/api/v1/label/{m1.group(1)}/values")
                    choices = (j or {}).get("data", [])
                else:
                    if q.startswith("query_result("):
                        q = q[len("query_result("):-1]
                    j, _ = api("/api/v1/query", query=q)
                    res = ((j or {}).get("data") or {}).get("result", [])
                    choices = [r["metric"].get("__name__", "") + "{" + ", ".join(
                        f'{k}="{val}"' for k, val in r["metric"].items() if k != "__name__") + "}" for r in res]
                rx = v.get("regex")
                if rx and choices:
                    try:
                        rxp = re.compile(re.sub(r"^/(.*)/[a-z]*$", r"\1", rx, flags=re.S).replace("(?<", "(?P<"))
                        out = []
                        for c in choices:
                            mm = rxp.search(c)
                            if mm:
                                gd = mm.groupdict()
                                out.append(gd.get("value") or gd.get("text") or (mm.group(1) if mm.groups() else c))
                        choices = out
                    except re.error:
                        pass
            if choices:
                vals[n] = ".*" if (v.get("includeAll") or v.get("multi")) else choices[0]
            else:
                vals[n] = ""  # Grafana renders a variable without options as an empty string
                novals.append(n)

        total = empty = errs = skipped = 0
        allp = list(db.get("panels") or []) + [x for r in db.get("rows") or [] for x in r.get("panels") or []]
        for p in panels(allp):
            if p.get("type") == "row":
                continue
            for t in p.get("targets") or []:
                if t.get("hide"):
                    continue
                ty = dstype(t.get("datasource") or p.get("datasource"))
                if ty in ("__expr__", "datasource", "grafana", "-- Grafana --", "-- Dashboard --"):
                    continue
                if ty != "prometheus":
                    skipped += 1
                    continue
                if not t.get("expr"):
                    continue
                e = subst(t["expr"], vals)
                e = re.sub(r'(\w+)="\.\*"', r'\1=~".*"', e)
                j, err = api("/api/v1/query", query=e)
                total += 1
                title = p.get("title", "?")
                if err:
                    errs += 1
                    print(f"  ERROR  {title} [{t.get('refId', '')}]: {err[:200]}\n         {e[:300]}")
                else:
                    n = len(j["data"]["result"]) if isinstance(j["data"]["result"], list) else 1
                    if n == 0:
                        empty += 1
                        print(f"  EMPTY  {title} [{t.get('refId', '')}]: {e[:300]}")
                    elif a.all:
                        print(f"  ok({n}) {title} [{t.get('refId', '')}]")
        errors += errs
        print(f"{path}: '{db.get('title')}' {total} queries, {empty} empty, {errs} errors, {skipped} non-Prometheus skipped"
              + (f", variables without values: {novals}" if novals else ""))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
