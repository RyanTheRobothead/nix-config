"""vulnscan-scan -- SBOMs, Grype rescans, the report and Discord alerts.

  vulnscan-scan scan              SBOM new digests, rescan everything, alert
  vulnscan-scan summary           post the daily summary
  vulnscan-scan notify-failure U  post that unit U failed

Reads the inventories vulnscan-inventory writes. Image SBOMs come from the
saved archive for this host's images and from the registry, by digest, for
other hosts'. A finding is one CVE in one container, however many of its
packages carry it. A finding pages when its container is public and it is in
CISA's Known Exploited Vulnerabilities catalog. The daily summary lists those
and every Critical on a public service, then anything else new.

Paths and the webhook come from VULNSCAN_* env vars set by the NixOS module.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

STATE = Path(os.environ.get("VULNSCAN_STATE", "/var/lib/vulnscan"))
SPOOL = Path(os.environ.get("VULNSCAN_SPOOL", "/var/cache/vulnscan/images"))
FIXTURE = os.environ.get("VULNSCAN_KEV_FIXTURE")
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


def syft(source, out):
    tmp = out.with_name(f".{out.name}.part")
    subprocess.run(
        ["syft", "-q", source, "-o", f"cyclonedx-json={tmp}"],
        check=True,
        env=TOOL_ENV,
    )
    os.replace(tmp, out)


def update_sboms(cs):
    """SBOM each digest in use once, and drop SBOMs nothing uses."""
    SBOMS.mkdir(parents=True, exist_ok=True)
    wanted = {}
    for c in cs:
        wanted.setdefault(c["digest"].removeprefix("sha256:"), c)
    for hexd, c in sorted(wanted.items()):
        out = SBOMS / f"{hexd}.cdx.json"
        if out.exists():
            continue
        source = image_source(c)
        if source is None:
            log(f"warning: no source for {c['host']}/{c['name']} ({c['digest']})")
            continue
        log(f"sbom {c['host']}/{c['name']} from {source}")
        try:
            syft(source, out)
        except subprocess.CalledProcessError as e:
            # One unreadable image shouldn't stop the rest being scanned
            log(f"warning: syft failed for {c['host']}/{c['name']}: {e}")
    for f in list(SBOMS.glob("*.cdx.json")) + list(RESULTS.glob("*.json")):
        hexd = f.name.split(".")[0]
        if not hexd.startswith("host-") and hexd not in wanted:
            log(f"removing {f.relative_to(STATE)}")
            f.unlink()


def update_host_sbom():
    """SBOM this host's system closure when it changes (after a switch).

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

    report = {
        "generated": now(),
        "unscanned": unscanned,
        "findings": findings,
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
    for key in set(state["seen"]) - set(current):
        state["resolved"][key] = now()
        del state["seen"][key]
    for key in current:
        state["seen"].setdefault(key, now())
        state["resolved"].pop(key, None)
    write_json(ALERTS, state)
    log(f"{len(findings)} findings, {sum(f['page'] for f in findings)} paging")


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
    title = (
        f"**Daily vulnerability summary** ({'; '.join(totals) or 'no findings'})\n"
        f"On public services: {len(paging)} known exploited, {len(critical)} other Critical. "
        f"{len(new)} new since the last summary"
    )
    lines = [describe(f) for f in paging + critical] + [
        describe(f) for f in new if not f["notable"]
    ]
    post(message(title, lines, "; ".join(footer_bits)))
    state["lastSummary"] = now()
    state["resolved"] = {}
    write_json(ALERTS, state)


def notify_failure(unit):
    post(f"**vulnscan:** `{unit}` failed on {HOST}; see `journalctl -u {unit}`")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "scan":
        scan()
    elif len(sys.argv) == 2 and sys.argv[1] == "summary":
        summary()
    elif len(sys.argv) == 3 and sys.argv[1] == "notify-failure":
        notify_failure(sys.argv[2])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
