# SPDX-License-Identifier: Apache-2.0
#
# Settings shared by all Tier 1 (trust plane) nodes.
{ config, lib, ... }:
{
  system.stateVersion = "26.05";

  # Measured boot (design 4.3). The Secure Boot key bundle is created on the
  # host with `sbctl` during provisioning.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
  };
  boot.initrd.systemd.enable = true;

  # Never swap secrets to disk.
  swapDevices = lib.mkForce [ ];

  # --- Trust plane services -------------------------------------------------
  trust.tpmUnseal = {
    enable = true;
    policyPcrs = [ "7" ]; # + signed PCR 11 policy once implemented
    lockPcr = "14";
  };

  trust.openbaoRoot = {
    enable = true;
    # Raft peers must reach 8200/8201 on each other. Tighten to per-source
    # nftables rules once the management network is final.
    openFirewall = true;
    # Offline-signed transport certificates, provisioned by the ceremony.
    tls = {
      certFile = "/var/lib/trust/tls/server.chain.pem";
      keyFile = "/var/lib/trust/tls/server.key";
      caFile = "/var/lib/trust/tls/root.pem";
    };
  };

  trust.spireDb = {
    enable = true;
    # Certificates issued by OpenBao `pki-infra` (OpenBao Agent, design 4.4).
    tls = {
      certFile = "/run/certs/db.chain.pem";
      keyFile = "/run/certs/db.key";
      caFile = "/var/lib/trust/tls/root.pem";
    };
  };

  trust.spire.server = {
    enable = true;
    database = {
      # Every DB node; the driver picks the read-write leader. Each node's
      # certificate carries its own name, so verify-full works per host.
      host = lib.concatStringsSep "," (lib.attrNames config.trust.spireDb.nodes);
      sslCert = "/run/certs/spire-db-client.pem";
      sslKey = "/run/certs/spire-db-client.key";
      sslRootCert = "/var/lib/trust/tls/root.pem";
    };
    upstream = {
      address = "https://${config.networking.hostName}:8200";
      caCertPath = "/var/lib/trust/tls/root.pem";
      clientCertPath = "/var/lib/trust/tls/node-client.pem";
      clientKeyPath = "/var/lib/trust/tls/node-client.key";
    };
  };

  # --- Administration (design 7) -------------------------------------------
  trust.adminAccess = {
    enable = true;
    bastionSources = [ "10.0.1.0/24" ];
    users = {
      # REPLACE with the real named accounts and FIDO2 (sk-) keys.
      alice = {
        role = "operator";
        sshKeys = [
          "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t REPLACE-ME alice"
        ];
      };
      bob = {
        role = "admin";
        sshKeys = [ "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t REPLACE-ME bob" ];
      };
    };
    # No `restart openbao.service`: a restart reseals the node and the TPM lock
    # PCR then blocks re-unsealing until the next reboot.
    operatorCommands = [
      "/run/current-system/sw/bin/systemctl status openbao.service"
    ];
    # The CI runner's source network must be listed in `bastionSources`.
    extraAllowedUsers = [ "deploy" ];
  };

  # Deployment account used by colmena from the CI runner (key supplied by the
  # runner's short-lived credentials, not by humans).
  users.users.deploy = {
    isSystemUser = true;
    group = "deploy";
    extraGroups = [ "trust-sudo" ];
    shell = "/run/current-system/sw/bin/bash";
    openssh.authorizedKeys.keys = [ ];
  };
  # colmena activates the system through sudo.
  security.sudo.extraRules = [
    {
      users = [ "deploy" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
  users.groups.deploy = { };
  nix.settings.trusted-users = [ "deploy" ];
}
