# SPDX-License-Identifier: Apache-2.0
#
# Named-account administration baseline (design 7.2, 7.3, 7.6).
#
# - only declared accounts, key-only SSH, no root login
# - SSH reachable only from the bastion networks
# - operators get a sudo allowlist; admins authenticate to sudo with their SSH
#   key through pam_ssh_agent_auth (works with FIDO2 keys)
# - auditd records privileged execs
#
# Out of scope here (see docs/ROADMAP.md): session recording, log shipping.
{
  config,
  lib,
  ...
}:
let
  cfg = config.trust.adminAccess;
  admins = lib.filterAttrs (_: u: u.role == "admin") cfg.users;
  operators = lib.filterAttrs (_: u: u.role == "operator") cfg.users;
in
{
  options.trust.adminAccess = {
    enable = lib.mkEnableOption "named-account admin baseline";

    bastionSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "10.0.0.0/24" ];
      description = "Source networks allowed to reach SSH (the bastion network).";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            role = lib.mkOption {
              type = lib.types.enum [
                "operator"
                "admin"
              ];
              description = "operator: runbook allowlist only. admin: full sudo via SSH-key authentication.";
            };
            sshKeys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Public keys; use FIDO2 `sk-ssh-ed25519@openssh.com` keys on real hosts.";
            };
          };
        }
      );
      default = { };
      description = "Named human accounts. No shared accounts.";
    };

    operatorCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/run/current-system/sw/bin/systemctl restart openbao.service" ];
      description = "Exact sudo commands operators may run without a password (runbook allowlist).";
    };

    extraAllowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "deploy" ];
      description = ''
        Non-human accounts (e.g. the CI deployment account) that may log in over
        SSH in addition to `users`. They are declared and given keys and sudo
        rights elsewhere; they are still subject to `bastionSources`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.mutableUsers = false;
    users.users =
      lib.mapAttrs (_: u: {
        isNormalUser = true;
        openssh.authorizedKeys.keys = u.sshKeys;
        extraGroups = [ "trust-sudo" ] ++ lib.optional (u.role == "admin") "wheel";
        hashedPassword = "!";
      }) cfg.users
      // {
        # Locked root (the NixOS test driver sets its own root password file).
        root.hashedPassword = lib.mkIf (config.users.users.root.hashedPasswordFile == null) "!";
      };

    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        AllowUsers = lib.attrNames cfg.users ++ cfg.extraAllowedUsers;
        AllowAgentForwarding = false;
        AllowTcpForwarding = false;
        X11Forwarding = false;
        MaxAuthTries = 3;
      };
      # Admins authenticate to sudo through their forwarded SSH agent
      # (pam_ssh_agent_auth), so forwarding is allowed for them only. This
      # Match block must stay last in sshd_config.
      extraConfig = lib.optionalString (admins != { }) ''
        Match User ${lib.concatStringsSep "," (lib.attrNames admins)}
          AllowAgentForwarding yes
      '';
    };

    networking.nftables.enable = true;
    networking.firewall.extraInputRules = ''
      ip saddr { ${lib.concatStringsSep ", " cfg.bastionSources} } tcp dport 22 accept
    '';

    users.groups.trust-sudo = { };
    security.wrappers.sudo = {
      group = lib.mkForce "trust-sudo";
      permissions = lib.mkForce "u+rx,g+x";
    };

    security.sudo = {
      enable = true;
      # Operators are not in wheel; only trust-sudo members may exec sudo.
      execWheelOnly = false;
      wheelNeedsPassword = true;
      extraRules = lib.mapAttrsToList (n: _: {
        users = [ n ];
        commands = map (c: {
          command = c;
          options = [ "NOPASSWD" ];
        }) cfg.operatorCommands;
      }) operators;
      extraConfig = ''
        Defaults use_pty, log_input, log_output, logfile="/var/log/sudo.log"
        Defaults env_reset
        # pam_ssh_agent_auth needs the forwarded agent socket.
        Defaults env_keep+=SSH_AUTH_SOCK
      '';
    };

    # Admins prove presence with their SSH key (agent) instead of a password.
    security.pam.rssh.enable = lib.mkIf (admins != { }) true;
    security.pam.services.sudo.rssh = lib.mkIf (admins != { }) true;

    security.auditd.enable = true;
    security.audit = {
      enable = true;
      rules = [
        "-a always,exit -F arch=b64 -S execve -k exec"
        "-w /etc/ssh/sshd_config -p wa -k ssh_config"
        "-w /var/lib/trust -p rwa -k trust_state"
      ];
    };
  };
}
