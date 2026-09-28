#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# mock_camunda.py - a stand-in for the Camunda Orchestration API, for tests
#
#   mock_camunda.py FIXTURE.json PORT_FILE LOG_FILE
#
# Serves the process definitions and instances in FIXTURE on a free port on
# 127.0.0.1, writes the port to PORT_FILE once it's listening, and appends
# every API request to LOG_FILE as a JSON line: {"method", "path", "body"}.
# It never changes its data, so tests are repeatable: they check what was
# sent, not what happened.
#
# Behaves like the real API where the scripts depend on it:
#   - OAuth client credentials (POST /oauth/token); API calls need the token
#   - searches with filter operators ($eq $neq $in $notIn $exists $lt $lte
#     $gt $gte), sort, and cursor paging (page.limit, page.after)
#   - unknown filter fields and page limits over 10000 are rejected (400)
#   - batch cancellation / deletion, and resource deletion
#
# Fixture keys (all optional):
#   definitions  process definitions; "state" defaults to ACTIVE, and
#                "isLatestVersion" is worked out per process id
#   instances    process instances; "processDefinitionId" and
#                "processDefinitionVersion" are filled in from the definition
#   clients      {"client id": "secret"}; default {"mock-client": "mock-secret"}
#   errors       [{"method", "path", "status", "body"}]: canned responses,
#                matched before anything else
#   topology     the GET /v2/topology response

import base64
import http.server
import json
import sys
import urllib.parse

DEFINITION_FIELDS = {
    "processDefinitionId", "processDefinitionKey", "name", "version", "versionTag",
    "resourceName", "tenantId", "hasStartForm", "isLatestVersion", "state",
}
INSTANCE_FIELDS = {
    "processInstanceKey", "processDefinitionKey", "processDefinitionId",
    "processDefinitionName", "processDefinitionVersion", "processDefinitionVersionTag",
    "state", "hasIncident", "tenantId", "parentProcessInstanceKey",
    "parentElementInstanceKey", "startDate", "endDate", "batchOperationId",
}
MAX_PAGE = 10000


def load(path):
    with open(path) as f:
        data = json.load(f)
    defs = data.setdefault("definitions", [])
    for d in defs:
        d.setdefault("state", "ACTIVE")
        d.setdefault("name", d["processDefinitionId"])
        d.setdefault("tenantId", "<default>")
    for d in defs:
        same = [x["version"] for x in defs if x["processDefinitionId"] == d["processDefinitionId"]]
        d["isLatestVersion"] = d["version"] == max(same)
    by_key = {d["processDefinitionKey"]: d for d in defs}
    for i in data.setdefault("instances", []):
        d = by_key.get(i["processDefinitionKey"], {})
        i.setdefault("processDefinitionId", d.get("processDefinitionId"))
        i.setdefault("processDefinitionVersion", d.get("version"))
        i.setdefault("parentProcessInstanceKey", None)
        i.setdefault("tenantId", "<default>")
    data.setdefault("clients", {"mock-client": "mock-secret"})
    data.setdefault("errors", [])
    data.setdefault("topology", {"brokers": [{"nodeId": 0}], "clusterSize": 1,
                                 "partitionsCount": 1, "gatewayVersion": "8.9.0"})
    return data


class BadRequest(Exception):
    pass


def matches(item, flt, fields):
    for name, cond in flt.items():
        if name not in fields:
            raise BadRequest("Request property [filter.%s] cannot be parsed" % name)
        value = item.get(name)
        if not isinstance(cond, dict):
            cond = {"$eq": cond}
        for op, arg in cond.items():
            if op == "$eq" and value != arg: return False
            if op == "$neq" and value == arg: return False
            if op == "$in" and value not in arg: return False
            if op == "$notIn" and value in arg: return False
            if op == "$exists" and (value is not None) != arg: return False
            if op in ("$lt", "$lte", "$gt", "$gte"):
                if value is None: return False
                if op == "$lt" and not value < arg: return False
                if op == "$lte" and not value <= arg: return False
                if op == "$gt" and not value > arg: return False
                if op == "$gte" and not value >= arg: return False
            if op not in ("$eq", "$neq", "$in", "$notIn", "$exists", "$lt", "$lte", "$gt", "$gte"):
                raise BadRequest("Request property [filter.%s.%s] cannot be parsed" % (name, op))
    return True


def search(items, body, fields):
    found = [i for i in items if matches(i, body.get("filter") or {}, fields)]
    for s in reversed(body.get("sort") or []):
        found.sort(key=lambda i: (i.get(s["field"]) is None, i.get(s["field"])),
                   reverse=s.get("order", "ASC").upper() == "DESC")
    page = body.get("page") or {}
    limit = page.get("limit", 100)
    if not isinstance(limit, int) or limit < 1 or limit > MAX_PAGE:
        raise BadRequest("page.limit must be between 1 and %d" % MAX_PAGE)
    start = 0
    if page.get("after"):
        start = int(base64.b64decode(page["after"]).decode()) + 1
    chunk = found[start:start + limit]
    cursor = lambda n: base64.b64encode(str(n).encode()).decode()
    return {
        "items": chunk,
        "page": {
            "totalItems": len(found),
            "hasMoreTotalItems": False,
            "startCursor": cursor(start) if chunk else None,
            "endCursor": cursor(start + len(chunk) - 1) if chunk else None,
        },
    }


def make_handler(data, log_path):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, obj):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def problem(self, status, title, detail=""):
            self.reply(status, {"type": "about:blank", "title": title, "status": status,
                                "detail": detail, "instance": self.path})

        def record(self, body):
            with open(log_path, "a") as log:
                log.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")

        def canned(self):
            for e in data["errors"]:
                if e.get("method", self.command) == self.command and e["path"] == self.path:
                    self.reply(e["status"], e.get("body", {"status": e["status"]}))
                    return True
            return False

        def authorised(self):
            auth = self.headers.get("Authorization", "")
            ok = any(auth == "Bearer mock-token-" + c for c in data["clients"])
            if not ok:
                self.problem(401, "Unauthorized")
            return ok

        def do_GET(self):
            self.record(None)
            if self.canned() or not self.authorised():
                return
            if self.path.endswith("/v2/topology"):
                return self.reply(200, data["topology"])
            self.problem(404, "NOT_FOUND")

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            if self.path.endswith("/oauth/token"):
                form = urllib.parse.parse_qs(raw)
                self.record({k: v[0] for k, v in form.items() if k != "client_secret"})
                client = form.get("client_id", [""])[0]
                if data["clients"].get(client) != form.get("client_secret", [""])[0]:
                    return self.reply(401, {"error": "unauthorized_client"})
                return self.reply(200, {"access_token": "mock-token-" + client,
                                        "expires_in": 3600, "token_type": "Bearer"})
            try:
                body = json.loads(raw) if raw else {}
            except ValueError:
                return self.problem(400, "INVALID_ARGUMENT", "not JSON")
            self.record(body)
            if self.canned() or not self.authorised():
                return
            path = self.path.split("/v2", 1)[-1]
            try:
                if path == "/process-definitions/search":
                    return self.reply(200, search(data["definitions"], body, DEFINITION_FIELDS))
                if path == "/process-instances/search":
                    return self.reply(200, search(data["instances"], body, INSTANCE_FIELDS))
                if path in ("/process-instances/cancellation", "/process-instances/deletion"):
                    # Validate the filter the way a search would.
                    search(data["instances"], {"filter": body.get("filter") or {}}, INSTANCE_FIELDS)
                    kind = "CANCEL_PROCESS_INSTANCE" if path.endswith("cancellation") else "DELETE_PROCESS_INSTANCE"
                    return self.reply(200, {"batchOperationKey": "batch-%d" % len(open(log_path).readlines()),
                                            "batchOperationType": kind})
                if path.startswith("/resources/") and path.endswith("/deletion"):
                    key = path.split("/")[2]
                    d = next((d for d in data["definitions"] if d["processDefinitionKey"] == key), None)
                    if d is None or d["state"] == "DELETED" and not body.get("deleteHistory"):
                        return self.problem(404, "NOT_FOUND", "no resource found with key `%s`" % key)
                    batch = None
                    if body.get("deleteHistory") and d["state"] == "DELETED":
                        batch = {"batchOperationKey": "history-" + key,
                                 "batchOperationType": "DELETE_PROCESS_DEFINITION"}
                    return self.reply(200, {"resourceKey": key, "batchOperation": batch})
            except BadRequest as e:
                return self.problem(400, "Bad Request", str(e))
            self.problem(404, "NOT_FOUND")

    return Handler


def main():
    fixture, port_file, log_path = sys.argv[1:4]
    data = load(fixture)
    open(log_path, "w").close()
    server = http.server.HTTPServer(("127.0.0.1", 0), make_handler(data, log_path))
    with open(port_file, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
