# SPDX-License-Identifier: Apache-2.0
#
# SPIRE server and agent wiring (design 3, 4.4).
#
# The signing CA comes from the root OpenBao `pki-spire` mount through the
# `vault` UpstreamAuthority (cert auth with the node identity, not a SPIRE JWT).
# UNTESTED SKELETON; there is no VM test yet (docs/ROADMAP.md).
{
  config,
  lib,
  ...
}:
let
  cfg = config.trust.spire;
in
{
  options.trust.spire = {
    server = {
      enable = lib.mkEnableOption "SPIRE server (Tier 1)";
      bindAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
      };
      database = {
        host = lib.mkOption {
          type = lib.types.str;
          default = "localhost";
          description = ''
            Database host(s); a comma-separated list is accepted. The name must
            match a SAN of the database server certificate (sslmode=verify-full).
          '';
        };
        sslCert = lib.mkOption { type = lib.types.str; };
        sslKey = lib.mkOption { type = lib.types.str; };
        sslRootCert = lib.mkOption { type = lib.types.str; };
      };
      upstream = {
        address = lib.mkOption {
          type = lib.types.str;
          example = "https://trust-node-01:8200";
        };
        caCertPath = lib.mkOption { type = lib.types.str; };
        clientCertPath = lib.mkOption { type = lib.types.str; };
        clientKeyPath = lib.mkOption { type = lib.types.str; };
        pkiMount = lib.mkOption {
          type = lib.types.str;
          default = "pki-spire";
        };
        certAuthRole = lib.mkOption {
          type = lib.types.str;
          default = "spire-server";
        };
      };
    };

    agent = {
      enable = lib.mkEnableOption "SPIRE agent";
      serverAddress = lib.mkOption { type = lib.types.str; };
      trustBundlePath = lib.mkOption { type = lib.types.str; };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.server.enable {
      services.spire.server = {
        enable = true;
        settings = {
          server = {
            bind_address = cfg.server.bindAddress;
            bind_port = 8081;
            trust_domain = config.trust.domain;
            data_dir = "/var/lib/spire-server";
            log_level = "INFO";
            # Short CA lifetime: rotation at half-life, tolerates days of
            # OpenBao outage (design 3.2).
            ca_ttl = "168h";
            default_x509_svid_ttl = "1h";
          };
          plugins = {
            DataStore = [
              {
                sql.plugin_data = {
                  database_type = "postgres";
                  connection_string = lib.concatStringsSep " " [
                    "host=${cfg.server.database.host}"
                    "dbname=spire"
                    # DB role; the client certificate CN `spire-server` is
                    # mapped to it by pg_ident (see spire-db.nix).
                    "user=spire"
                    "target_session_attrs=read-write"
                    "sslmode=verify-full"
                    "sslcert=${cfg.server.database.sslCert}"
                    "sslkey=${cfg.server.database.sslKey}"
                    "sslrootcert=${cfg.server.database.sslRootCert}"
                  ];
                };
              }
            ];
            # No long-term signing key on disk: the CA is issued upstream.
            KeyManager = [ { memory.plugin_data = { }; } ];
            UpstreamAuthority = [
              {
                vault.plugin_data = {
                  vault_addr = cfg.server.upstream.address;
                  ca_cert_path = cfg.server.upstream.caCertPath;
                  pki_mount_point = cfg.server.upstream.pkiMount;
                  cert_auth = {
                    cert_auth_mount_point = "cert";
                    cert_auth_role_name = cfg.server.upstream.certAuthRole;
                    client_cert_path = cfg.server.upstream.clientCertPath;
                    client_key_path = cfg.server.upstream.clientKeyPath;
                  };
                };
              }
            ];
          };
        };
      };
    })

    (lib.mkIf cfg.agent.enable {
      services.spire.agent = {
        enable = true;
        settings = {
          agent = {
            server_address = cfg.agent.serverAddress;
            server_port = 8081;
            trust_domain = config.trust.domain;
            trust_bundle_path = cfg.agent.trustBundlePath;
            data_dir = "/var/lib/spire-agent";
          };
        };
      };
    })
  ];
}
