# SPDX-License-Identifier: Apache-2.0
#
# TPM-sealed OpenBao unseal key with a runtime lock (design 4.3, 4.5).
#
# The sealed object is bound to `policyPcrs` plus the lock PCR. The unseal
# service releases the key, unseals OpenBao, then extends the lock PCR so any
# later attempt (by any process) fails until the next reboot.
#
# Restarting openbao.service reseals the node, and the lock PCR then blocks
# the unseal service until the next reboot: recover such a node by rebooting it.
#
# NOT IMPLEMENTED YET: the signed PCR 11 policy (systemd-measure pcrsig +
# PolicyAuthorize). `policyPcrs` is a plain PCR list for now; see docs/ROADMAP.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.trust.tpmUnseal;
  tools = pkgs.callPackage ../pkgs/trust-tpm-tools { };
in
{
  options.trust.tpmUnseal = {
    enable = lib.mkEnableOption "TPM-sealed OpenBao unseal key with runtime lock";

    sealedDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/trust/sealed";
      description = "Where the sealed TPM object (public and private blobs) is stored.";
    };

    policyPcrs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "7" ];
      description = ''
        PCRs the sealed key is bound to. Real hosts use 7 (Secure Boot policy);
        the signed PCR 11 policy replaces a raw 11 once implemented.
        PCR 0 and 2 are deliberately not used (firmware updates would brick
        unattended recovery).
      '';
    };

    lockPcr = lib.mkOption {
      type = lib.types.str;
      default = "14";
      description = ''
        PCR extended after a successful unseal. It must be unused by the boot
        chain and by systemd on the target image: systemd may extend PCR 15
        (machine id, cryptsetup volume keys) at boot, which races with the
        unseal service, so the default is 14. Verify on the real image.
      '';
    };

    unsealTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "How long the service keeps retrying `sys/unseal` (e.g. while a joiner waits for the leader).";
    };

    openbaoSocket = lib.mkOption {
      type = lib.types.str;
      default = "/run/openbao/openbao.sock";
      description = "Local OpenBao unix socket used for unsealing (never a network address).";
    };
  };

  config = lib.mkIf cfg.enable {
    security.tpm2.enable = true;
    environment.systemPackages = [
      tools
      pkgs.tpm2-tools
    ];

    environment.etc."trust/tpm.env".text = ''
      TRUST_SEALED_DIR=${cfg.sealedDir}
      TRUST_POLICY_PCRS=${lib.concatStringsSep "," cfg.policyPcrs}
      TRUST_LOCK_PCR=${cfg.lockPcr}
      TRUST_OPENBAO_SOCKET=${cfg.openbaoSocket}
      TRUST_UNSEAL_TIMEOUT=${toString cfg.unsealTimeoutSeconds}
    '';

    systemd.tmpfiles.rules = [ "d ${cfg.sealedDir} 0700 root root - -" ];

    # Everything that needs secrets or the network of the trust plane orders
    # itself `After=openbao-unseal.service` (see the other modules).
    systemd.services.openbao-unseal = {
      description = "Unseal OpenBao from the TPM-sealed key, then lock the TPM policy";
      wantedBy = [ "multi-user.target" ];
      after = [ "openbao.service" ];
      requires = [ "openbao.service" ];
      environment.TPM2TOOLS_TCTI = "device:/dev/tpmrm0";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${tools}/bin/trust-openbao-unseal";
        Restart = "on-failure";
        RestartSec = 10;
        # 3 = the TPM refused to release the key (tampered boot chain or lock
        # PCR already extended). Retrying cannot help; the node needs a reboot.
        RestartPreventExitStatus = "3";
        # No network needed: unix socket and TPM device only.
        PrivateNetwork = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        LimitCORE = 0;
        MemorySwapMax = 0;
      };
      unitConfig = {
        StartLimitIntervalSec = 0;
      };
    };
  };
}
