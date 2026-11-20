# SPDX-License-Identifier: Apache-2.0
#
# Admin baseline (design 7.3): named accounts, key-only SSH, bastion-only
# source network, operator sudo allowlist, no root login.
{ self, pkgs, ... }:
let
  # The snake-oil Ed25519 key pair from the OpenSSH fuzz tests
  # (regress/misc/fuzz-harness/fixed-keys.h) — the same test keys
  # nixpkgs ships in nixos/tests/ssh-keys.nix. Inlined rather than
  # imported from ${pkgs.path} because dereferencing the nixpkgs source
  # store path is flaky under cached CI flakes (the path can be
  # invalidated while the rest of the evaluation reads a different copy).
  snakeOilEd25519PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDPQXmEVMVLmeFRyafKMVWgPDkv8/uRBTwmcEDatZzMD snakeoil";

  snakeOilEd25519PrivateKey = pkgs.writeText "privkey.snakeoil" ''
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACAz0F5hFTFS5nhUcmnyjFVoDw5L/P7kQU8JnBA2rWczAwAAAIhWlP99VpT/
    fQAAAAtzc2gtZWQyNTUxOQAAACAz0F5hFTFS5nhUcmnyjFVoDw5L/P7kQU8JnBA2rWczAw
    AAAEDE1rlcMC0s0X3TKVZAOVavZOywwkXw8tO5dLObxaCMEDPQXmEVMVLmeFRyafKMVWgP
    Dkv8/uRBTwmcEDatZzMDAAAAAAECAwQF
    -----END OPENSSH PRIVATE KEY-----
  '';
in
pkgs.testers.runNixOSTest {
  name = "trust-admin-access";

  nodes = {
    target =
      { nodes, ... }:
      {
        imports = [ self.nixosModules.default ];
        users.users.ci = {
          isSystemUser = true;
          group = "ci";
          shell = "/run/current-system/sw/bin/bash";
          openssh.authorizedKeys.keys = [ snakeOilEd25519PublicKey ];
        };
        users.groups.ci = { };
        trust.adminAccess = {
          enable = true;
          bastionSources = [ nodes.bastion.networking.primaryIPAddress ];
          users.alice = {
            role = "operator";
            sshKeys = [ snakeOilEd25519PublicKey ];
          };
          users.bob = {
            role = "admin";
            sshKeys = [ snakeOilEd25519PublicKey ];
          };
          extraAllowedUsers = [ "ci" ];
          operatorCommands = [
            "/run/current-system/sw/bin/systemctl is-active sshd.service"
          ];
        };
      };

    bastion =
      { ... }:
      {
        programs.ssh.extraConfig = "StrictHostKeyChecking no";
      };

    intruder =
      { ... }:
      {
        programs.ssh.extraConfig = "StrictHostKeyChecking no";
      };
  };

  testScript = ''
    start_all()
    target.wait_for_unit("sshd.service")

    # Every driver call gets an explicit per-command timeout: without one a
    # command that hangs (e.g. when the test driver's console channel stalls
    # on a loaded CI runner) would otherwise burn the whole 3600 s global
    # test timeout before the failure is visible.
    for n in (bastion, intruder):
        n.succeed("install -m 600 ${snakeOilEd25519PrivateKey} /root/key", timeout=60)

    ssh = "ssh -i /root/key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5"

    with subtest("named operator can log in from the bastion network"):
        bastion.succeed(f"{ssh} alice@target true", timeout=60)

    with subtest("root login is refused"):
        bastion.fail(f"{ssh} root@target true", timeout=60)

    with subtest("password authentication is disabled"):
        bastion.fail(
            "ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "
            "-o BatchMode=yes -o ConnectTimeout=5 alice@target true",
            timeout=60,
        )

    with subtest("other networks cannot even reach SSH"):
        intruder.fail(f"{ssh} alice@target true", timeout=60)

    with subtest("undeclared users are refused"):
        bastion.fail(f"{ssh} nobody@target true", timeout=60)

    with subtest("operator sudo is limited to the allowlist"):
        bastion.succeed(
            f"{ssh} alice@target /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl is-active sshd.service",
            timeout=60,
        )
        bastion.fail(f"{ssh} alice@target /run/wrappers/bin/sudo -n id", timeout=60)
        bastion.fail(
            f"{ssh} alice@target /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart sshd.service",
            timeout=60,
        )

    with subtest("admin authenticates to sudo through the forwarded agent"):
        bastion.succeed(
            "eval $(ssh-agent) && ssh-add /root/key && "
            f"{ssh} -A bob@target /run/wrappers/bin/sudo id </dev/null | grep -q uid=0",
            timeout=60,
        )
        # Without a forwarded agent the admin cannot escalate. (No `-n` above:
        # pam_ssh_agent_auth only runs when sudo may talk to PAM.)
        bastion.fail(f"{ssh} bob@target /run/wrappers/bin/sudo id </dev/null", timeout=60)

    with subtest("operators cannot forward an agent"):
        bastion.succeed(
            "eval $(ssh-agent) && ssh-add /root/key && "
            f"{ssh} -A alice@target 'test -z \"$SSH_AUTH_SOCK\"'",
            timeout=60,
        )

    with subtest("extra allowed accounts can log in but have no sudo"):
        bastion.succeed(f"{ssh} ci@target true", timeout=60)
        bastion.fail(f"{ssh} ci@target /run/wrappers/bin/sudo -n id", timeout=60)

    with subtest("privileged commands are audited"):
        target.succeed("auditctl -l | grep -q 'key=exec'", timeout=60)
        # The allowlisted sudo call above must have left an exec record.
        target.succeed("ausearch -k exec -i | grep -q is-active", timeout=60)
  '';
}
