# SPDX-License-Identifier: Apache-2.0
#
# Root OpenBao: one Raft HA cluster on the Tier 1 nodes (design 4.2).
#
# The module only configures the daemon. Initialisation (exactly once, on the
# bootstrap node), key delivery to the TPMs, audit devices, mounts and policies
# are done by the day-0 ceremony and by CI (see docs/ROADMAP.md).
{
  config,
  lib,
  ...
}:
let
  cfg = config.trust.openbaoRoot;
  hostName = config.networking.hostName;
  cred = "/run/credentials/openbao.service";
in
{
  options.trust.openbaoRoot = {
    enable = lib.mkEnableOption "root OpenBao (Tier 1)";

    nodeId = lib.mkOption {
      type = lib.types.str;
      default = hostName;
      description = "Raft node id.";
    };

    joinPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "trust-node-01" ];
      description = ''
        Hosts to `retry_join`. Empty on the bootstrap node (the only one that
        is ever initialised); the other nodes list the bootstrap node.
      '';
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8200;
    };
    clusterPort = lib.mkOption {
      type = lib.types.port;
      default = 8201;
    };

    tls = {
      certFile = lib.mkOption {
        type = lib.types.path;
        description = "Server certificate chain (PEM), signed by the offline transport CA.";
      };
      keyFile = lib.mkOption {
        type = lib.types.path;
        description = "Private key (PEM). Loaded through systemd credentials, never read by the service user directly.";
      };
      caFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Trust anchor (offline root) used to verify the leader on `retry_join`
          and by local clients (`BAO_CACERT`). The API listener does not demand
          client certificates at the TLS layer; cert auth is enforced by the
          OpenBao auth mounts.
        '';
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the API and cluster ports. Prefer restricting them per source in nftables.";
    };

    auditDevices = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Audit device path (must be unique across the cluster).";
            };
            filePath = lib.mkOption {
              type = lib.types.str;
              description = "Log file of the file audit device.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        File-based audit devices, created declaratively by OpenBao at unseal
        time (design 7.7 requires at least two, so the cluster keeps serving
        when one sink fails). OpenBao refuses to start if the configuration
        diverges from the stored audit table, so every node of the cluster
        must agree on these devices.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.openbao = {
      enable = true;
      settings = {
        ui = false;
        api_addr = "https://${hostName}:${toString cfg.apiPort}";
        cluster_addr = "https://${hostName}:${toString cfg.clusterPort}";

        listener = {
          api = {
            type = "tcp";
            address = "0.0.0.0:${toString cfg.apiPort}";
            cluster_address = "0.0.0.0:${toString cfg.clusterPort}";
            tls_cert_file = "${cred}/tls.crt";
            tls_key_file = "${cred}/tls.key";
            tls_min_version = "tls13";
            # Recovery without a human (design 8): once the root token is
            # revoked, a new one is generated from the unseal key through
            # the unauthenticated /v1/sys/generate-root endpoints.
            disable_unauthed_generate_root_endpoints = false;
          };
          # Local-only listener used by the unseal helper (design 4.3).
          local = {
            type = "unix";
            address = config.trust.tpmUnseal.openbaoSocket;
            socket_mode = "0600";
          };
        };

        storage.raft = {
          path = "/var/lib/openbao";
          node_id = cfg.nodeId;
        }
        // lib.optionalAttrs (cfg.joinPeers != [ ]) {
          retry_join = map (p: {
            leader_api_addr = "https://${p}:${toString cfg.apiPort}";
            leader_ca_cert_file = toString cfg.tls.caFile;
          }) cfg.joinPeers;
        };

        # Declarative audit devices (design 7.7). Each device body needs at
        # least two keys in the rendered JSON, so `description` is set even
        # though it only labels the device.
        audit = lib.optionals (cfg.auditDevices != [ ]) (
          map (d: {
            file.${d.name} = {
              description = "file audit device";
              options.file_path = d.filePath;
            };
          }) cfg.auditDevices
        );
      };
    };

    systemd.services.openbao.serviceConfig = {
      LoadCredential = [
        "tls.crt:${toString cfg.tls.certFile}"
        "tls.key:${toString cfg.tls.keyFile}"
      ];
      # Audit devices write here (two devices, see design 7.7).
      LogsDirectory = "openbao";
      LogsDirectoryMode = "0750";
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.apiPort
      cfg.clusterPort
    ];

    environment.variables = {
      BAO_ADDR = lib.mkDefault "https://${hostName}:${toString cfg.apiPort}";
      BAO_CACERT = lib.mkDefault (toString cfg.tls.caFile);
    };
  };
}
