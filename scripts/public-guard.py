#!/usr/bin/env python3
"""Fail if a public hostname leads to a namespace that isn't hardened (M5.5).

Reads rendered manifests (kubectl kustomize output, one or more files or
stdin) and follows each hostname in the cloudflared tunnel's ingress rules to
the namespaces it reaches: the HTTPRoute serving it, and any backend in
another namespace. Each of those namespaces must have:

  - the Pod Security Admission label  pod-security.kubernetes.io/enforce: restricted
  - a default-deny CiliumNetworkPolicy (endpointSelector: {}, ingress and egress)
  - on every workload: automountServiceAccountToken: false, runAsNonRoot,
    seccompProfile RuntimeDefault; on every container: no privilege
    escalation, a read-only root filesystem, ALL capabilities dropped,
    CPU and memory requests and a memory limit

Workloads rendered by a HelmRelease aren't in the manifests, so they get a
warning to check in the cluster instead. See docs/ADDING_A_SERVICE.md
"Before going public". Used by .github/workflows/public-guard.yml.

Usage:
  kubectl kustomize apps/prod > /tmp/apps.yaml
  kubectl kustomize infrastructure/configs > /tmp/infra.yaml
  python3 scripts/public-guard.py /tmp/apps.yaml /tmp/infra.yaml
"""

import sys

import yaml

TUNNEL_CONFIGMAP = ("cloudflared", "cloudflared-config")
WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"}

errors = []
warnings = []


def error(msg):
    errors.append(msg)
    print(f"::error::{msg}")


def warning(msg):
    warnings.append(msg)
    print(f"::warning::{msg}")


def load(paths):
    docs = []
    for path in paths or ["-"]:
        stream = sys.stdin if path == "-" else open(path, encoding="utf-8")
        with stream:
            docs.extend(d for d in yaml.safe_load_all(stream) if isinstance(d, dict))
    return docs


def ns_of(doc):
    return doc.get("metadata", {}).get("namespace")


def name_of(doc):
    return doc.get("metadata", {}).get("name")


def public_hosts(docs):
    """(public hostname, Host the Gateway sees) for each tunnel ingress rule."""
    for doc in docs:
        if doc.get("kind") == "ConfigMap" and (ns_of(doc), name_of(doc)) == TUNNEL_CONFIGMAP:
            config = yaml.safe_load(doc.get("data", {}).get("config.yaml", "")) or {}
            for rule in config.get("ingress") or []:
                if rule.get("hostname"):
                    origin = rule.get("originRequest") or {}
                    yield rule["hostname"], origin.get("httpHostHeader") or rule["hostname"]
            return
    error(f"tunnel ConfigMap {TUNNEL_CONFIGMAP[0]}/{TUNNEL_CONFIGMAP[1]} not found in the rendered manifests")


def host_matches(pattern, host):
    if pattern.startswith("*."):
        suffix = pattern[1:]
        return host.endswith(suffix) and "." not in host[: -len(suffix)]
    return pattern == host


def reached_namespaces(docs, public, host):
    """Namespaces of the HTTPRoutes serving host, and of their backends."""
    namespaces = set()
    for doc in docs:
        if doc.get("kind") != "HTTPRoute":
            continue
        spec = doc.get("spec", {})
        if not any(host_matches(p, host) for p in spec.get("hostnames") or []):
            continue
        namespaces.add(ns_of(doc))
        for rule in spec.get("rules") or []:
            for ref in rule.get("backendRefs") or []:
                namespaces.add(ref.get("namespace") or ns_of(doc))
    if not namespaces:
        error(f"{public}: no HTTPRoute serves {host}, so its namespace can't be checked")
    return namespaces


def pod_spec(doc):
    spec = doc.get("spec", {})
    kind = doc["kind"]
    if kind == "Pod":
        return spec
    if kind == "CronJob":
        spec = spec.get("jobTemplate", {}).get("spec", {})
    return spec.get("template", {}).get("spec", {})


def check_namespace(docs, public, ns):
    where = f"{public} -> namespace {ns}"
    namespace = next((d for d in docs if d.get("kind") == "Namespace" and name_of(d) == ns), None)
    if namespace is None:
        error(f"{where}: no Namespace manifest in git, so its labels can't be checked")
    else:
        labels = namespace.get("metadata", {}).get("labels") or {}
        if labels.get("pod-security.kubernetes.io/enforce") != "restricted":
            error(f"{where}: missing label pod-security.kubernetes.io/enforce: restricted")

    check_default_deny(docs, where, ns)

    for doc in docs:
        if doc.get("kind") == "HelmRelease" and ns in (ns_of(doc), doc.get("spec", {}).get("targetNamespace")):
            warning(f"{where}: HelmRelease {name_of(doc)} renders workloads CI can't see; check their hardening in the cluster")
        if doc.get("kind") in WORKLOAD_KINDS and ns_of(doc) == ns:
            check_workload(f"{where}: {doc['kind']} {name_of(doc)}", pod_spec(doc))


def check_default_deny(docs, where, ns):
    directions = set()
    for doc in docs:
        if doc.get("kind") != "CiliumNetworkPolicy" or ns_of(doc) != ns:
            continue
        specs = ([doc["spec"]] if "spec" in doc else []) + (doc.get("specs") or [])
        for spec in specs:
            # {} selects every endpoint in the namespace; once selected, a
            # direction with rules denies whatever they don't allow.
            if spec.get("endpointSelector") not in ({}, {"matchLabels": {}}):
                continue
            if "ingress" in spec or "ingressDeny" in spec:
                directions.add("ingress")
            if "egress" in spec or "egressDeny" in spec:
                directions.add("egress")
    for direction in ("ingress", "egress"):
        if direction not in directions:
            error(f"{where}: no default-deny CiliumNetworkPolicy for {direction} (endpointSelector: {{}})")


def check_workload(where, spec):
    if spec.get("automountServiceAccountToken") is not False:
        error(f"{where}: automountServiceAccountToken is not false")
    pod_sc = spec.get("securityContext") or {}
    containers = (spec.get("initContainers") or []) + (spec.get("containers") or [])
    for c in containers:
        sc = c.get("securityContext") or {}
        cw = f"{where}, container {c.get('name')}"
        if not sc.get("runAsNonRoot", pod_sc.get("runAsNonRoot")):
            error(f"{cw}: runAsNonRoot is not true")
        seccomp = (sc.get("seccompProfile") or pod_sc.get("seccompProfile") or {}).get("type")
        if seccomp != "RuntimeDefault":
            error(f"{cw}: seccompProfile is not RuntimeDefault")
        if sc.get("allowPrivilegeEscalation") is not False:
            error(f"{cw}: allowPrivilegeEscalation is not false")
        if sc.get("readOnlyRootFilesystem") is not True:
            error(f"{cw}: readOnlyRootFilesystem is not true")
        if "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []):
            error(f"{cw}: capabilities don't drop ALL")
        resources = c.get("resources") or {}
        requests = resources.get("requests") or {}
        if "cpu" not in requests or "memory" not in requests:
            error(f"{cw}: needs CPU and memory requests")
        if "memory" not in (resources.get("limits") or {}):
            error(f"{cw}: needs a memory limit")


def main():
    docs = load(sys.argv[1:])
    checked = 0
    for public, host in public_hosts(docs):
        for ns in sorted(reached_namespaces(docs, public, host)):
            check_namespace(docs, public, ns)
            checked += 1
    print(f"public-guard: {checked} namespace check(s), {len(errors)} error(s), {len(warnings)} warning(s)")
    if errors:
        print("Fix these before publishing: docs/ADDING_A_SERVICE.md, \"Before going public\".")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
