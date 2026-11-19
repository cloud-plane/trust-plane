# SPDX-License-Identifier: Apache-2.0
#
# SPIRE datastore: PostgreSQL under Patroni with a 3-member etcd DCS, all
# inside the trust boundary (design 8.4).
#
# UNTESTED SKELETON: evaluates, but there is no VM test for it yet (see
# docs/ROADMAP.md). The nixpkgs patroni test is the reference for the
# non-TLS shape of this configuration.
#
# The `spire` database and role are not created here; the day-0 ceremony
# creates them on the first leader. Clients authenticate with a certificate
# whose CN is `spire-server`, mapped to the role `spire` by pg_ident.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.trust.spireDb;
  hostName = config.networking.hostName;
  names = lib.attrNames cfg.nodes;
  others = lib.filterAttrs (n: _: n != hostName) cfg.nodes;
in
{
  options.trust.spireDb = {
    enable = lib.mkEnableOption "PostgreSQL/Patroni/etcd for the SPIRE datastore";

    nodes = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.ip = lib.mkOption {
            type = lib.types.str;
            description = "Address Patroni uses to identify the node.";
          };
        }
      );
      default = { };
      description = "The three database nodes (host name -> address).";
    };

    scope = lib.mkOption {
      type = lib.types.str;
      default = "spire";
    };

    postgresqlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_17;
    };

    tls = {
      certFile = lib.mkOption { type = lib.types.path; };
      keyFile = lib.mkOption { type = lib.types.path; };
      caFile = lib.mkOption { type = lib.types.path; };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length names == 3;
        message = "trust.spireDb.nodes must list exactly three nodes.";
      }
      {
        assertion = cfg.nodes ? ${hostName};
        message = "this host (${hostName}) is not in trust.spireDb.nodes.";
      }
      {
        assertion = config.networking.nftables.enable;
        message = "trust.spireDb opens peer ports through networking.firewall.extraInputRules, which needs nftables.";
      }
    ];

    # Peers only: etcd client/peer, Patroni REST, PostgreSQL. SPIRE servers
    # connect to PostgreSQL from the Tier 1 nodes, which are the peers.
    networking.firewall.extraInputRules = lib.mkIf (others != { }) ''
      ip saddr { ${
        lib.concatStringsSep ", " (lib.mapAttrsToList (_: n: n.ip) others)
      } } tcp dport { 2379, 2380, 5432, 8008 } accept
    '';

    services.etcd = {
      enable = true;
      name = hostName;
      listenClientUrls = [ "https://0.0.0.0:2379" ];
      advertiseClientUrls = [ "https://${hostName}:2379" ];
      listenPeerUrls = [ "https://0.0.0.0:2380" ];
      initialAdvertisePeerUrls = [ "https://${hostName}:2380" ];
      initialCluster = map (n: "${n}=https://${n}:2380") names;
      certFile = toString cfg.tls.certFile;
      keyFile = toString cfg.tls.keyFile;
      trustedCaFile = toString cfg.tls.caFile;
      peerCertFile = toString cfg.tls.certFile;
      peerKeyFile = toString cfg.tls.keyFile;
      peerTrustedCaFile = toString cfg.tls.caFile;
      clientCertAuth = true;
      peerClientCertAuth = true;
    };

    services.patroni = {
      enable = true;
      inherit (cfg) scope postgresqlPackage;
      name = hostName;
      nodeIp = cfg.nodes.${hostName}.ip;
      otherNodesIps = lib.mapAttrsToList (_: n: n.ip) others;
      settings = {
        bootstrap.dcs = {
          ttl = 30;
          loop_wait = 10;
          retry_timeout = 10;
          # Failover must not lose acknowledged writes (design 8.4).
          synchronous_mode = true;
          synchronous_mode_strict = true;
          maximum_lag_on_failover = 1048576;
        };
        etcd3 = {
          hosts = lib.concatMapStringsSep "," (n: "${n}:2379") names;
          protocol = "https";
          cacert = toString cfg.tls.caFile;
          cert = toString cfg.tls.certFile;
          key = toString cfg.tls.keyFile;
        };
        postgresql = {
          use_pg_rewind = true;
          use_slots = true;
          parameters = {
            listen_addresses = "*";
            wal_level = "replica";
            ssl = "on";
            ssl_cert_file = toString cfg.tls.certFile;
            ssl_key_file = toString cfg.tls.keyFile;
            ssl_ca_file = toString cfg.tls.caFile;
          };
          # Certificate-only authentication: no passwords, no peer auth.
          pg_hba = [
            "hostssl replication replicator all cert clientcert=verify-full"
            "hostssl spire spire all cert clientcert=verify-full map=spire"
          ];
          pg_ident = [ "spire spire-server spire" ];
        };
      };
    };
  };
}
