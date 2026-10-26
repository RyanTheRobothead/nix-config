// Public DNS for every domain, applied to deSEC with DNSControl.
//
//   just dns-check     validate this file offline (no credentials)
//   just dns-preview   diff against deSEC (needs DESEC_TOKEN)
//   just dns-push      apply that diff
//
// Imported 2026-10-26 from Squarespace's DNS API, with TXT values checked
// against the live ns-cloud-*.googledomains.com servers. Differences from the
// Squarespace zones are forced by deSEC and marked "deSEC:" below.

var REG_NONE = NewRegistrar("none"); // Squarespace stays registrar until the Porkbun transfer
var DSP_DESEC = NewDnsProvider("desec");

// Cerberus (Linode). Phase 2 moves these names to SleeperService.
var CERBERUS = "23.239.27.17";

// GitHub Pages apex addresses, from GitHub's custom-domain docs.
var GITHUB_PAGES = [
  A("@", "185.199.108.153"),
  A("@", "185.199.109.153"),
  A("@", "185.199.110.153"),
  A("@", "185.199.111.153"),
  AAAA("@", "2606:50c0:8000::153"),
  AAAA("@", "2606:50c0:8001::153"),
  AAAA("@", "2606:50c0:8002::153"),
  AAAA("@", "2606:50c0:8003::153"),
];

// Squarespace's _domainconnect CNAME is dropped from every zone: it only
// serves Squarespace's own Domain Connect templates.

D("ryandlewis.dev", REG_NONE, DnsProvider(DSP_DESEC),
  DefaultTTL(3600),

  // Website: GitHub Pages. deSEC: no ALIAS records, so the apex carries
  // GitHub's published addresses instead of ALIAS ryantherobothead.github.io.
  GITHUB_PAGES,
  CNAME("www", "ryantherobothead.github.io."),

  // Services behind SWAG on Cerberus. The wildcard catches every other name.
  A("*", CERBERUS),
  A("cloud", CERBERUS),
  A("foundry", CERBERUS),
  A("immich", CERBERUS, TTL(14400)),
  A("neofoundry", CERBERUS),
  A("plex", CERBERUS, TTL(14400)),
  A("request", CERBERUS),
  A("warden", CERBERUS),

  // Proton Mail
  MX("@", 10, "mail.protonmail.ch."),
  MX("@", 10, "mailsec.protonmail.ch."),
  TXT("@", "protonmail-verification=79858b7fbd5a4ec5bf701b72e678d61283a55395"),
  TXT("@", "v=spf1 include:_spf.protonmail.ch mx ~all"),
  TXT("_dmarc", "v=DMARC1; p=quarantine"),
  CNAME("protonmail._domainkey", "protonmail.domainkey.dzsr6ovwfm52a3bcskiedtz7f3fo3sn6qbv2flcua7wb3witz6vla.domains.proton.ch."),
  CNAME("protonmail2._domainkey", "protonmail2.domainkey.dzsr6ovwfm52a3bcskiedtz7f3fo3sn6qbv2flcua7wb3witz6vla.domains.proton.ch."),
  CNAME("protonmail3._domainkey", "protonmail3.domainkey.dzsr6ovwfm52a3bcskiedtz7f3fo3sn6qbv2flcua7wb3witz6vla.domains.proton.ch."),

  // Amazon SES: custom MAIL FROM on mail., DKIM on the apex
  MX("mail", 10, "feedback-smtp.us-east-2.amazonses.com."),
  TXT("mail", "v=spf1 include:amazonses.com ~all"),
  CNAME("4cuerc6hx7bvcoxq5grrl6ckkk6smj7z._domainkey", "4cuerc6hx7bvcoxq5grrl6ckkk6smj7z.dkim.amazonses.com."),
  CNAME("6l6ktyphfqj35fg5xn6qvwpoeiefy76v._domainkey", "6l6ktyphfqj35fg5xn6qvwpoeiefy76v.dkim.amazonses.com."),
  CNAME("7fpvaqf4vyrk33rpm4mbg7a5ykr2gpuq._domainkey", "7fpvaqf4vyrk33rpm4mbg7a5ykr2gpuq.dkim.amazonses.com."),

  // Google site verification. deSEC: its minimum TTL is 3600 (was 300).
  CNAME("jjr4erbqmker", "gv-5j5vm46um2zkpo.dv.googlehosted.com."),
END);

// robothead.dev and luckierdodge.dev only redirect to ryandlewis.dev. At
// Squarespace that was its forwarding service (apex A to a Squarespace IP,
// www CNAME ext-sq.squarespace.com). deSEC has no forwarding, so both names
// point at the public proxy: SWAG on Cerberus serves the 301 from
// nginx/site-confs/redirect-domains.conf (added 2026-10-26). .dev is
// HSTS-preloaded, so at cutover, once these names resolve there, issue their
// own certificate as that file describes; until then it serves SWAG's
// ryandlewis.dev certificate as a placeholder.
function redirectToRyandlewis(verification) {
  return [
    A("@", CERBERUS),
    A("www", CERBERUS),
    verification,
  ];
}

// Both zones have DNSSEC on at Squarespace: remove their DS records there
// and wait out the TTL before switching nameservers.
D("robothead.dev", REG_NONE, DnsProvider(DSP_DESEC),
  DefaultTTL(3600),
  redirectToRyandlewis(CNAME("ajd3tkfqnvi6", "gv-ftv4nyjx72binn.dv.googlehosted.com.")),
END);

D("luckierdodge.dev", REG_NONE, DnsProvider(DSP_DESEC),
  DefaultTTL(3600),
  redirectToRyandlewis(CNAME("7mlni7bg26nu", "gv-q37q45htgmei7g.dv.googlehosted.com.")),
END);
