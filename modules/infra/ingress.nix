# Public ingress on SleeperService: nginx with Let's Encrypt certificates,
# replacing SWAG on Cerberus. Certificates use DNS-01 through deSEC with the
# acme-sleeperservice token (dns/mk-tokens.sh), which can only write
# _acme-challenge TXT records, so one wildcard covers every service name and
# keeps them out of certificate transparency logs.
{ config, pkgs, ... }:
{
  sops.secrets.desec_token_acme_sleeperservice.sopsFile = ../../secrets/sleeperservice/desec.yaml;
  sops.templates."acme-desec-env".content = ''
    DESEC_TOKEN=${config.sops.placeholder.desec_token_acme_sleeperservice}
  '';

  security.acme = {
    acceptTerms = true;
    defaults = {
      dnsProvider = "desec";
      environmentFile = config.sops.templates."acme-desec-env".path;
      group = "nginx";
      # lego's check passes once the nameservers it asks have the challenge,
      # but deSEC's ns2 is anycast and its nodes lag ns1 by minutes, so Let's
      # Encrypt's vantage points could still miss it (seen on the first order:
      # the apex validated, the wildcard got "no TXT record"). Wait instead.
      extraLegoFlags = [
        "--dns.propagation-wait"
        "300s"
      ];
    };
    certs."ryandlewis.dev".extraDomainNames = [ "*.ryandlewis.dev" ];
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    # Names nothing here serves: close plain connections, and refuse TLS
    # handshakes rather than present a certificate for the wrong name
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };

    # Phase 1's check that ingress and the wildcard work end to end
    virtualHosts."test.ryandlewis.dev" = {
      useACMEHost = "ryandlewis.dev";
      forceSSL = true;
      root = pkgs.writeTextDir "index.html" ''
        <!doctype html>
        <title>SleeperService</title>
        <p>SleeperService ingress works.</p>
      '';
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
