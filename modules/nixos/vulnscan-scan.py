"""vulnscan-scan -- SBOMs, Grype rescans, the report and Discord alerts.

  vulnscan-scan scan              SBOM new digests, rescan everything, alert
  vulnscan-scan summary           post the daily summary
  vulnscan-scan notify-failure U  post that unit U failed
  vulnscan-scan nix-trial         run both Nix closure scanners, record results

Reads the inventories vulnscan-inventory writes. Image SBOMs come from the
saved archive for this host's images and from the registry, by digest, for
other hosts'. A finding is one CVE in one container, however many of its
packages carry it. A finding pages when its container is public and it is in
CISA's Known Exploited Vulnerabilities catalog. The daily summary lists those
and every Critical on a public service, then anything else new.

Trust: every CA bundle in every image (captured by Syft alongside the SBOM)
and on this host is checked against security/ca-denylist.toml, as are the
runtimes that carry their own trust decisions. New trust findings post once.
Fix watches (security/fix-watch.toml) post when a fix appears and again when
every watched container runs it.

Paths and the webhook come from VULNSCAN_* env vars set by the NixOS module.
"""

import base64
import csv
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

STATE = Path(os.environ.get("VULNSCAN_STATE", "/var/lib/vulnscan"))
SPOOL = Path(os.environ.get("VULNSCAN_SPOOL", "/var/cache/vulnscan/images"))
FIXTURE = os.environ.get("VULNSCAN_KEV_FIXTURE")
TRUST_FIXTURE = os.environ.get("VULNSCAN_TRUST_FIXTURE")
# Makes Syft capture CA bundle contents alongside each SBOM
SYFT_CONFIG = os.environ.get("VULNSCAN_SYFT_CONFIG")
CA_DENYLIST = os.environ.get("VULNSCAN_CA_DENYLIST")
FIX_WATCH = os.environ.get("VULNSCAN_FIX_WATCH")
WEBHOOK_FILE = os.environ.get("VULNSCAN_WEBHOOK_FILE")
# Write Discord messages to this file instead of posting them
DRY_RUN = os.environ.get("VULNSCAN_DISCORD_DRY_RUN")
HOST = os.environ.get("VULNSCAN_HOST", socket.gethostname())
SYSTEM = os.environ.get("VULNSCAN_SYSTEM", "/run/current-system")

INVENTORY = STATE / "inventory"
SBOMS = STATE / "sbom"
RESULTS = STATE / "results"
REPORT = STATE / "report" / "report.json"
ALERTS = STATE / "report" / "alerts.json"
METRICS = STATE / "metrics" / "vulnscan.prom"

SEVERITIES = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]
DISCORD_LIMIT = 2000
TOOL_ENV = {
    **os.environ,
    "SYFT_CHECK_FOR_APP_UPDATE": "false",
    "GRYPE_CHECK_FOR_APP_UPDATE": "false",
    # Updated once per run, explicitly, below
    "GRYPE_DB_AUTO_UPDATE": "false",
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def write_json(path, data):
    """Replace path atomically, so readers never see half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.chmod(f.name, 0o640)
    os.replace(f.name, path)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def containers():
    """Every container in every inventory, with its host."""
    out = []
    for inv in sorted(INVENTORY.glob("*.json")):
        data = json.loads(inv.read_text())
        for c in data["containers"]:
            out.append({**c, "host": data["host"]})
    return out


def inventory_snapshot():
    return {p.name: p.read_bytes() for p in INVENTORY.glob("*.json")}


def image_source(c):
    """Where Syft reads this container's image from, or None."""
    hexd = c["digest"].removeprefix("sha256:")
    archive = SPOOL / f"{hexd}.tar"
    if c["host"] == HOST and archive.exists():
        return f"docker-archive:{archive}"
    for ref in c["repoDigests"]:
        if ref.endswith("@" + c["digest"]):
            return f"registry:{ref}"
    return None


def pem_fingerprints(text):
    """SHA-256 of each certificate's DER in a PEM bundle."""
    blocks = re.findall(
        r"-----BEGIN (?:TRUSTED )?CERTIFICATE-----(.*?)-----END (?:TRUSTED )?CERTIFICATE-----",
        text,
        re.S,
    )
    return sorted({hashlib.sha256(base64.b64decode("".join(b.split()))).hexdigest() for b in blocks})


def sbom_path(hexd):
    return SBOMS / f"{hexd}.cdx.json"


def cas_path(hexd):
    """The image's CA bundles: {path: [fingerprints]}."""
    return SBOMS / f"{hexd}.cas.json"


def syft(source, hexd):
    """SBOM an image, keeping only the fingerprints of its CA bundles."""
    out = sbom_path(hexd)
    tmp = out.with_name(f".{out.name}.part")
    files = out.with_name(f".{hexd}.syft.json.part")
    cmd = ["syft", source, "-o", f"cyclonedx-json={tmp}"]
    if SYFT_CONFIG:
        cmd += ["-c", SYFT_CONFIG, "-o", f"syft-json={files}"]
    # Not -q: that hides the reason when a pull fails
    run = subprocess.run(cmd, capture_output=True, text=True, env=TOOL_ENV)
    if run.returncode != 0:
        tmp.unlink(missing_ok=True)
        files.unlink(missing_ok=True)
        reason = " | ".join(run.stderr.strip().splitlines()[-3:])
        raise RuntimeError(f"syft exited {run.returncode}: {reason}")
    if SYFT_CONFIG:
        bundles = {}
        for f in json.loads(files.read_text()).get("files", []):
            if f.get("contents"):
                pem = base64.b64decode(f["contents"]).decode(errors="replace")
                bundles[f["location"]["path"]] = pem_fingerprints(pem)
        files.unlink()
        write_json(cas_path(hexd), {"bundles": bundles})
    os.replace(tmp, out)


def update_sboms(cs):
    """SBOM each digest in use once, and drop SBOMs nothing uses."""
    SBOMS.mkdir(parents=True, exist_ok=True)
    wanted = {}
    for c in cs:
        wanted.setdefault(c["digest"].removeprefix("sha256:"), c)
    for hexd, c in sorted(wanted.items()):
        if sbom_path(hexd).exists() and (not SYFT_CONFIG or cas_path(hexd).exists()):
            continue
        source = image_source(c)
        if source is None:
            log(f"warning: no source for {c['host']}/{c['name']} ({c['digest']})")
            continue
        log(f"sbom {c['host']}/{c['name']} from {source}")
        try:
            syft(source, hexd)
        except RuntimeError as e:
            # One unreadable image shouldn't stop the rest being scanned
            log(f"warning: syft failed for {c['host']}/{c['name']}: {e}")
    stale = list(SBOMS.glob("*.cdx.json")) + list(SBOMS.glob("*.cas.json"))
    for f in stale + list(RESULTS.glob("*.json")):
        hexd = f.name.split(".")[0]
        if not hexd.startswith("host-") and hexd not in wanted:
            log(f"removing {f.relative_to(STATE)}")
            f.unlink()


def update_host_sbom():
    """SBOM this host's system closure when it has changed since the last.

    Scanned in a later step; generated here so it tracks every switch.
    """
    system = os.path.realpath(SYSTEM)
    marker = SBOMS / f"host-{HOST}.system"
    if marker.exists() and marker.read_text().strip() == system:
        return
    log(f"sbom {HOST} system {system}")
    out = SBOMS / f"host-{HOST}.cdx.json"
    with tempfile.TemporaryDirectory(dir=SBOMS) as tmp:
        # sbomnix also writes SPDX and CSV into its working directory
        subprocess.run(
            ["sbomnix", system, "--cdx", f"{tmp}/sbom.cdx.json"],
            check=True,
            cwd=tmp,
            stdout=subprocess.DEVNULL,
        )
        os.replace(f"{tmp}/sbom.cdx.json", out)
    marker.write_text(system + "\n")


def grype(sbom):
    out = subprocess.run(
        ["grype", "-q", f"sbom:{sbom}", "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
        env=TOOL_ENV,
    ).stdout
    return json.loads(out)


def cve_id(match):
    """The CVE for a match, so a GHSA renamed to its CVE isn't 'new'."""
    vid = match["vulnerability"]["id"]
    if vid.startswith("CVE-"):
        return vid
    for related in match.get("relatedVulnerabilities", []):
        if related["id"].startswith("CVE-"):
            return related["id"]
    return vid


def known_exploited(match):
    if match["vulnerability"].get("knownExploited"):
        return True
    return any(r.get("knownExploited") for r in match.get("relatedVulnerabilities", []))


def findings_for(c, scan):
    """One finding per CVE in this container, merging the packages it hits."""
    by_id = {}
    for m in scan.get("matches", []):
        vid = cve_id(m)
        vuln = m["vulnerability"]
        f = by_id.setdefault(
            vid,
            {
                "key": f"{c['host']}/{c['name']}/{vid}",
                "host": c["host"],
                "container": c["name"],
                "exposure": c["exposure"],
                "id": vid,
                "severity": "Unknown",
                "kev": False,
                "packages": [],
                "fixedIn": [],
            },
        )
        sev = vuln.get("severity", "Unknown")
        if sev not in SEVERITIES:
            sev = "Unknown"
        if SEVERITIES.index(sev) < SEVERITIES.index(f["severity"]):
            f["severity"] = sev
        f["kev"] = f["kev"] or known_exploited(m)
        art = m["artifact"]
        pkg = f"{art['name']} {art['version']}"
        if pkg not in f["packages"]:
            f["packages"].append(pkg)
        for v in vuln.get("fix", {}).get("versions", []):
            if v not in f["fixedIn"]:
                f["fixedIn"].append(v)
    for f in by_id.values():
        public = f["exposure"] == "public"
        # Critical alone is too common to page on (Debian and Alpine carry
        # many with no fix); those wait for the summary
        f["page"] = public and f["kev"]
        f["notable"] = public and (f["kev"] or f["severity"] == "Critical")
    return list(by_id.values())


def self_test():
    """Fail loudly if Grype's output stops showing KEV where we look."""
    if not FIXTURE:
        return
    scan = grype(FIXTURE)
    if not any(known_exploited(m) for m in scan.get("matches", [])):
        raise SystemExit(
            "self-test: the Log4Shell fixture shows no KEV entry; "
            "Grype's JSON has changed, so KEV paging is broken"
        )


def load_toml(path):
    if not path:
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)


def version_key(v):
    """Digits in order: go1.27.2 -> (1, 27, 2); 8.5.11-r1 -> (8, 5, 11, 1)."""
    return tuple(int(x) for x in re.findall(r"\d+", v.removeprefix("go")))


def runtime_fix(version, rt):
    """(passes, the fix on its line or None) under the denylist's line rule."""
    v = version_key(version)
    line = rt["line"]
    fixes = sorted(version_key(f) for f in rt["fixed"])
    same = [f for f in fixes if f[:line] == v[:line]]
    if same:
        return v >= same[0], ".".join(map(str, same[0]))
    return v[:line] > max(f[:line] for f in fixes), None


def components(sbom):
    """(purl without version, version) for every component in a CycloneDX SBOM."""
    out = []
    for comp in read_json(sbom, {}).get("components", []):
        purl = comp.get("purl", "")
        if "@" in purl and comp.get("version"):
            out.append((purl.split("@")[0], comp["version"]))
    return out


def host_bundles():
    """This host's CA bundles: the system one and any certifi in the closure.

    nixpkgs' certifi uses NIX_SSL_CERT_FILE over its own cacert.pem when set;
    this unit gets the same environment as other services, so follow suit.
    """
    paths = ["/etc/ssl/certs/ca-certificates.crt"]
    if os.environ.get("NIX_SSL_CERT_FILE"):
        return {p: pem_fingerprints(Path(p).read_text()) for p in {paths[0], os.environ["NIX_SSL_CERT_FILE"]}}
    closure = subprocess.run(
        ["nix-store", "-qR", os.path.realpath(SYSTEM)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    for store_path in closure:
        if "certifi" in store_path:
            paths += [str(p) for p in Path(store_path).glob("lib/*/site-packages/certifi/cacert.pem")]
    return {p: pem_fingerprints(Path(p).read_text()) for p in paths if os.path.exists(p)}


def trust_findings(denylist, where, exposure, bundles, comps):
    """One finding per distrusted certificate or unfixed runtime in one place."""
    out = []
    for cert in denylist.get("certificate", []):
        paths = sorted(p for p, fps in bundles.items() if cert["sha256"] in fps)
        if paths:
            out.append(
                {
                    "key": f"{where}/trust/{cert['name']}",
                    "where": where,
                    "exposure": exposure,
                    "kind": "certificate",
                    "name": cert["name"],
                    "paths": paths,
                    "why": cert["why"],
                }
            )
    for rt in denylist.get("runtime", []):
        bad = []
        for purl, version in comps:
            if purl in rt["purls"]:
                ok, fix = runtime_fix(version, rt)
                if not ok and version not in [b[0] for b in bad]:
                    bad.append((version, fix))
        if bad:
            out.append(
                {
                    "key": f"{where}/trust/{rt['name']}",
                    "where": where,
                    "exposure": exposure,
                    "kind": "runtime",
                    "name": rt["name"],
                    "versions": [{"version": v, "fixedIn": f} for v, f in bad],
                    "why": rt["why"],
                }
            )
    return out


def check_trust(cs):
    """Trust findings for every container and this host, and what went unchecked."""
    denylist = load_toml(CA_DENYLIST)
    if not denylist:
        return [], []
    found, unchecked = [], []
    for c in cs:
        where = f"{c['host']}/{c['name']}"
        hexd = c["digest"].removeprefix("sha256:")
        cas = read_json(cas_path(hexd))
        if cas is None or not sbom_path(hexd).exists():
            # Not checked is not clean
            unchecked.append(where)
            continue
        found += trust_findings(
            denylist, where, c["exposure"], cas["bundles"], components(sbom_path(hexd))
        )
    host_sbom = SBOMS / f"host-{HOST}.cdx.json"
    found += trust_findings(
        denylist, f"{HOST}/(system)", "host", host_bundles(), components(host_sbom)
    )
    return found, unchecked


def check_watches(cs, scans):
    """Each fix watch's state in every container it names."""
    out = []
    for w in load_toml(FIX_WATCH).get("watch", []):
        status = {"name": w["name"], "then": w["then"], "containers": []}
        for where in w["containers"]:
            host, name = where.split("/", 1)
            c = next((c for c in cs if c["host"] == host and c["name"] == name), None)
            entry = {"where": where, "state": "unchecked", "versions": []}
            if c is not None:
                hexd = c["digest"].removeprefix("sha256:")
                comps = components(sbom_path(hexd)) if sbom_path(hexd).exists() else None
                if comps is not None:
                    entry["versions"] = sorted({v for p, v in comps if p in w["purls"]})
                    # A distro may backport the fix without the upstream
                    # release: trust Grype's fixed version when it has one
                    learned = sorted(
                        (
                            fv
                            for m in scans.get(hexd, {}).get("matches", [])
                            if cve_id(m) in w["cves"]
                            for fv in m["vulnerability"].get("fix", {}).get("versions", [])
                        ),
                        key=version_key,
                    )
                    entry["threshold"] = learned[0] if learned else w["fixed"]
                    entry["learned"] = bool(learned)
                    fixed = all(
                        version_key(v) >= version_key(entry["threshold"])
                        for v in entry["versions"]
                    )
                    # No such package any more counts as fixed
                    entry["state"] = "fixed" if fixed else "waiting"
            status["containers"].append(entry)
        states = [e["state"] for e in status["containers"]]
        status["done"] = all(s == "fixed" for s in states)
        status["fixKnown"] = any(e.get("learned") for e in status["containers"])
        out.append(status)
    return out


def trust_self_test():
    """Fail loudly if a planted emSign G3 certificate isn't caught."""
    if not TRUST_FIXTURE:
        return
    bundles = {TRUST_FIXTURE: pem_fingerprints(Path(TRUST_FIXTURE).read_text())}
    hits = trust_findings(load_toml(CA_DENYLIST), "self-test", "local", bundles, [])
    if not any(h["name"] == "emSign ECC Root CA - G3" for h in hits):
        raise SystemExit("self-test: the planted emSign G3 certificate wasn't flagged")


def describe_trust(group):
    """One line per place: everything it trusts that it shouldn't."""
    where = group[0]["where"]
    bits = []
    certs = [t for t in group if t["kind"] == "certificate"]
    if certs:
        paths = sorted({p for t in certs for p in t["paths"]})
        shown = ", ".join(paths[:2]) + (f" +{len(paths) - 2}" if len(paths) > 2 else "")
        bits.append(f"trusts {', '.join(t['name'] for t in certs)} ({shown})")
    for t in group:
        if t["kind"] == "runtime":
            for v in t["versions"]:
                fix = (
                    f"fixed in {v['fixedIn']}"
                    if v["fixedIn"]
                    else "no fix on this release line"
                )
                bits.append(f"{t['name']} {v['version'].removeprefix('go')}: {fix}")
    return f"{where}: " + "; ".join(bits)


def trust_lines(trust):
    groups = {}
    for t in trust:
        groups.setdefault(t["where"], []).append(t)
    # Public services first
    order = {"public": 0, "host": 1, "tailnet": 2, "local": 3}
    return [
        describe_trust(g)
        for _, g in sorted(groups.items(), key=lambda kv: (order.get(kv[1][0]["exposure"], 9), kv[0]))
    ]


def describe_watch(w):
    parts = []
    for e in w["containers"]:
        versions = ", ".join(e["versions"]) or "not present"
        if e["state"] == "unchecked":
            parts.append(f"{e['where']} not checked")
        else:
            parts.append(f"{e['where']} {versions} (needs {e['threshold']})")
    return f"{w['name']}: " + "; ".join(parts)


def rank(f):
    # Pages first, then by severity, with what can be patched now leading
    return (
        not f["page"],
        SEVERITIES.index(f["severity"]),
        not f["kev"],
        not f["fixedIn"],
        f["key"],
    )


def describe(f):
    pkgs = ", ".join(f["packages"][:2])
    if len(f["packages"]) > 2:
        pkgs += f" +{len(f['packages']) - 2}"
    kev = ", known exploited" if f["kev"] else ""
    if f["fixedIn"]:
        fix = "fixed in " + ", ".join(f["fixedIn"][:2])
    else:
        fix = "no fix yet: mitigate"
    return f"{f['host']}/{f['container']}: {f['id']} {f['severity']}{kev} in {pkgs}; {fix}"


def message(title, lines, footer=""):
    """A Discord message that fits, ending with how many lines didn't."""
    out = [title]
    for i, line in enumerate(lines):
        rest = len(lines) - i
        more = f"...and {rest} more in {REPORT}"
        if len("\n".join(out + ["- " + line, more, footer])) > DISCORD_LIMIT:
            out.append(more)
            break
        out.append("- " + line)
    if footer:
        out.append(footer)
    return "\n".join(out)


def post(content):
    if DRY_RUN:
        with open(DRY_RUN, "a") as f:
            f.write(content + "\n---\n")
        return
    if not WEBHOOK_FILE or not os.path.exists(WEBHOOK_FILE):
        log("no Discord webhook configured; message follows")
        log(content)
        return
    url = Path(WEBHOOK_FILE).read_text().strip()
    body = json.dumps({"content": content, "allowed_mentions": {"parse": []}})
    req = urllib.request.Request(
        url,
        data=body.encode(),
        headers={"Content-Type": "application/json", "User-Agent": "vulnscan"},
    )
    urllib.request.urlopen(req, timeout=30).close()


def write_metrics(report):
    lines = [
        "# HELP vulnscan_findings Open findings, one per container and CVE",
        "# TYPE vulnscan_findings gauge",
    ]
    counts = {}
    for f in report["findings"]:
        k = (f["host"], f["exposure"], f["severity"])
        counts[k] = counts.get(k, 0) + 1
    for (host, exposure, sev), n in sorted(counts.items()):
        lines.append(
            f'vulnscan_findings{{host="{host}",exposure="{exposure}",severity="{sev}"}} {n}'
        )
    lines += [
        "# HELP vulnscan_trust_findings Places trusting a distrusted root or running an unfixed runtime",
        "# TYPE vulnscan_trust_findings gauge",
        f"vulnscan_trust_findings {len({t['where'] for t in report['trust']})}",
        "# HELP vulnscan_fix_watch_waiting Fix watches still waiting for a fixed image",
        "# TYPE vulnscan_fix_watch_waiting gauge",
        f"vulnscan_fix_watch_waiting {sum(not w['done'] for w in report['watches'])}",
        "# HELP vulnscan_last_scan_timestamp_seconds When the last scan finished",
        "# TYPE vulnscan_last_scan_timestamp_seconds gauge",
        f"vulnscan_last_scan_timestamp_seconds {int(time.time())}",
    ]
    METRICS.parent.mkdir(parents=True, exist_ok=True)
    tmp = METRICS.with_name(f".{METRICS.name}.part")
    tmp.write_text("\n".join(lines) + "\n")
    os.chmod(tmp, 0o640)
    os.replace(tmp, METRICS)


def scan():
    cs = containers()
    update_sboms(cs)
    update_host_sbom()
    subprocess.run(["grype", "-q", "db", "update"], check=True, env=TOOL_ENV)
    self_test()
    trust_self_test()

    RESULTS.mkdir(parents=True, exist_ok=True)
    scans = {}
    findings = []
    for c in cs:
        hexd = c["digest"].removeprefix("sha256:")
        sbom = SBOMS / f"{hexd}.cdx.json"
        if not sbom.exists():
            continue
        if hexd not in scans:
            scans[hexd] = grype(sbom)
            write_json(RESULTS / f"{hexd}.json", scans[hexd])
        findings += findings_for(c, scans[hexd])
    findings.sort(key=rank)
    unscanned = sorted(
        f"{c['host']}/{c['name']}"
        for c in cs
        if not (SBOMS / f"{c['digest'].removeprefix('sha256:')}.cdx.json").exists()
    )

    trust, unchecked = check_trust(cs)
    watches = check_watches(cs, scans)

    report = {
        "generated": now(),
        "unscanned": unscanned,
        "findings": findings,
        "trust": trust,
        "trustUnchecked": unchecked,
        "watches": watches,
    }
    write_json(REPORT, report)
    write_metrics(report)

    state = read_json(ALERTS)
    current = {f["key"]: f for f in findings}
    if state is None:
        # First run: one message for what's already there, not a flood
        state = {"seen": {}, "resolved": {}, "lastSummary": now()}
        paging = [f for f in findings if f["page"]]
        if paging:
            title = (
                f"**Vulnerability scanning is live.** {len(paging)} findings on "
                f"public services are known exploited:"
            )
        else:
            title = (
                "**Vulnerability scanning is live.** Nothing on public services "
                "is known exploited; Criticals are in the daily summary."
            )
        post(message(title, [describe(f) for f in paging]))
    else:
        new = [f for f in findings if f["page"] and f["key"] not in state["seen"]]
        if new:
            post(
                message(
                    f"**{len(new)} new vulnerabilities on public services**",
                    [describe(f) for f in new],
                )
            )
    alert_trust(state, trust)
    alert_watches(state, watches)
    for key in set(state["seen"]) - set(current):
        state["resolved"][key] = now()
        del state["seen"][key]
    for key in current:
        state["seen"].setdefault(key, now())
        state["resolved"].pop(key, None)
    write_json(ALERTS, state)
    log(f"{len(findings)} findings, {sum(f['page'] for f in findings)} paging")


def alert_trust(state, trust):
    seen = state.get("trustSeen")
    if seen is None:
        # First trust check: one message for what's already there
        seen = {}
        if trust:
            title = (
                f"**Trust-store check is live.** {len({t['where'] for t in trust})} "
                "places trust distrusted roots or run a runtime without the fix:"
            )
        else:
            title = "**Trust-store check is live.** Nothing trusts a distrusted root."
        post(message(title, trust_lines(trust)))
    else:
        new = [t for t in trust if t["key"] not in seen]
        if new:
            post(message(f"**{len(new)} new trust findings**", trust_lines(new)))
    state["trustSeen"] = {t["key"]: seen.get(t["key"], now()) for t in trust}


def alert_watches(state, watches):
    prev = state.setdefault("watches", {})
    for w in watches:
        was = prev.get(w["name"], {})
        if w["done"] and not was.get("done"):
            post(
                message(
                    f"**{w['name']} is fixed** in every watched container. Now: {w['then']}",
                    [describe_watch(w)],
                )
            )
        elif w["fixKnown"] and not was.get("fixKnown"):
            post(
                message(
                    f"**{w['name']}: a fix exists.** Waiting for the images to update.",
                    [describe_watch(w)],
                )
            )
        prev[w["name"]] = {"done": w["done"], "fixKnown": w["fixKnown"]}


def summary():
    report = read_json(REPORT)
    state = read_json(ALERTS)
    if report is None or state is None:
        raise SystemExit("no report yet; has vulnscan-scan run?")
    since = state["lastSummary"]
    findings = report["findings"]
    totals = []
    for host in sorted({f["host"] for f in findings}):
        counts = [
            f"{sum(f['host'] == host and f['severity'] == s for f in findings)} {s}"
            for s in SEVERITIES[:3]
        ]
        totals.append(f"{host}: " + ", ".join(counts))
    new = [f for f in findings if state["seen"].get(f["key"], "") > since]
    resolved = [k for k, t in state["resolved"].items() if t > since]
    paging = [f for f in findings if f["page"]]
    critical = [f for f in findings if f["notable"] and not f["page"]]
    footer_bits = [f"{len(resolved)} resolved since the last summary"]
    if report["unscanned"]:
        footer_bits.append("not scanned: " + ", ".join(report["unscanned"]))
    trust = report.get("trust", [])
    unchecked = report.get("trustUnchecked", [])
    waiting = [w for w in report.get("watches", []) if not w["done"]]
    title = (
        f"**Daily vulnerability summary** ({'; '.join(totals) or 'no findings'})\n"
        f"On public services: {len(paging)} known exploited, {len(critical)} other Critical. "
        f"{len(new)} new since the last summary. "
        f"Trust: {len({t['where'] for t in trust})} places flagged, {len(unchecked)} unchecked; "
        f"{len(waiting)} fix watches waiting"
    )
    lines = [describe(f) for f in paging + critical] + [
        describe(f) for f in new if not f["notable"]
    ]
    post(message(title, lines, "; ".join(footer_bits)))
    # Its own message, so the Critical list can't push it off the end
    if trust or unchecked or waiting:
        detail = [describe_watch(w) for w in waiting] + trust_lines(trust)
        if unchecked:
            detail.append("trust not checked: " + ", ".join(unchecked))
        post(message("**Trust and fix watches**", detail))
    state["lastSummary"] = now()
    state["resolved"] = {}
    write_json(ALERTS, state)


TRIAL = STATE / "trial"
TRIAL_DAYS = 45


def nix_trial():
    """Scan the system closure with vulnix and with vulnxscan, and keep both.

    A month of these decides which scanner stays (Phase 6): fewer false
    alarms wins, and a scanner that can't fetch its data counts against it.
    Nothing alerts; a run that fails is recorded, not raised.
    """
    system = os.path.realpath(SYSTEM)
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    out = TRIAL / day
    out.mkdir(parents=True, exist_ok=True)
    row = {"date": day, "system": system}

    # vulnix fetches NVD's yearly feeds, which time out often: try twice.
    # Exit 0 is clean, 2 is vulnerabilities found, anything else an error.
    for attempt in (1, 2):
        run = subprocess.run(
            ["vulnix", "--json", system], capture_output=True, text=True
        )
        if run.returncode in (0, 2):
            break
    if run.returncode in (0, 2):
        found = json.loads(run.stdout or "[]")
        (out / "vulnix.json").write_text(run.stdout)
        row["vulnix"] = {
            "ok": True,
            "attempts": attempt,
            "findings": sum(len(d.get("affected_by", [])) for d in found),
        }
    else:
        (out / "vulnix.err").write_text(run.stderr[-20000:])
        reason = (run.stderr.strip().splitlines() or ["no output"])[-1]
        row["vulnix"] = {"ok": False, "attempts": attempt, "error": reason[:300]}

    # vulnxscan runs vulnix, Grype and OSV and merges them; it carries on
    # without any that fail, so record which ones made it into the table
    with tempfile.TemporaryDirectory(dir=out) as tmp:
        run = subprocess.run(
            ["vulnxscan", system, "--out", f"{tmp}/vulns.csv"],
            capture_output=True,
            text=True,
            cwd=tmp,
        )
        if run.returncode == 0 and os.path.exists(f"{tmp}/vulns.csv"):
            os.replace(f"{tmp}/vulns.csv", out / "vulnxscan.csv")
            with open(out / "vulnxscan.csv", newline="") as f:
                rows = list(csv.DictReader(f))
            scanners = [k for k in ("vulnix", "grype", "osv") if rows and k in rows[0]]
            row["vulnxscan"] = {
                "ok": True,
                "findings": len(rows),
                "scanners": scanners,
                "by": {k: sum(r.get(k) == "1" for r in rows) for k in scanners},
            }
        else:
            (out / "vulnxscan.err").write_text(run.stderr[-20000:])
            row["vulnxscan"] = {"ok": False, "error": (run.stderr.strip().splitlines() or ["no output"])[-1][:300]}

    with open(TRIAL / "summary.jsonl", "a") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")
    cutoff = time.time() - TRIAL_DAYS * 86400
    for d in TRIAL.iterdir():
        if d.is_dir() and d.stat().st_mtime < cutoff:
            for f in d.iterdir():
                f.unlink()
            d.rmdir()
    log(json.dumps(row))


def notify_failure(unit):
    post(f"**vulnscan:** `{unit}` failed on {HOST}; see `journalctl -u {unit}`")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "scan":
        # An inventory written mid-scan fires the path unit while this is
        # still running, and systemd drops that trigger; rescan instead
        for _ in range(3):
            before = inventory_snapshot()
            scan()
            if inventory_snapshot() == before:
                break
            log("inventory changed during the scan; rescanning")
    elif len(sys.argv) == 2 and sys.argv[1] == "summary":
        summary()
    elif len(sys.argv) == 3 and sys.argv[1] == "notify-failure":
        notify_failure(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "nix-trial":
        nix_trial()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
