# SPDX-License-Identifier: Apache-2.0
#
# TPM-bound secret handling (design 4.3, 4.5 steps 1 and 4):
#  - the secret is delivered with an EK-bound credential (makecredential /
#    activatecredential): another TPM cannot receive it
#  - it is sealed locally, and released only for the right PCR state
#  - the lock PCR makes a second release fail until reboot
{ self, pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "trust-tpm-seal";

  defaults =
    { ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.tpm.enable = true;
      security.tpm2.enable = true;
      environment.systemPackages = [
        (pkgs.callPackage ../pkgs/trust-tpm-tools { })
        pkgs.jq
        pkgs.tpm2-tools
      ];
      environment.etc."trust/tpm.env".text = ''
        TRUST_SEALED_DIR=/var/lib/trust/sealed
        TRUST_POLICY_PCRS=13
        TRUST_LOCK_PCR=14
      '';
    };

  nodes = {
    machine = { };
    other = { };
  };

  testScript = ''
    TAMPER = "ab" * 32

    def read_b64(node, path):
        return node.succeed(f"base64 -w0 {path}").strip()

    def put_b64(node, path, data):
        node.succeed(f"echo {data} | base64 -d > {path}")

    def reboot(node):
        node.shutdown()
        node.start()
        node.wait_for_unit("multi-user.target")

    start_all()
    machine.wait_for_unit("multi-user.target")
    other.wait_for_unit("multi-user.target")

    with subtest("both nodes enrol their EK and AK"):
        for n in (machine, other):
            n.succeed("trust-tpm-enroll /root/enroll")
            n.succeed("test -s /root/enroll/ek.pub && test -s /root/enroll/ak.name.hex")
            # Enrolment is idempotent.
            n.succeed("trust-tpm-enroll /root/enroll")

    ak_name = machine.succeed("cat /root/enroll/ak.name.hex").strip()

    with subtest("credential made for machine's EK is received by machine"):
        put_b64(other, "/root/machine-ek.pub", read_b64(machine, "/root/enroll/ek.pub"))
        # `other` plays the admin workstation: makecredential needs no TPM.
        other.succeed(
            f"printf 'the-unseal-key' | trust-tpm-makecredential --ek /root/machine-ek.pub --name {ak_name} --out /root/cred.blob"
        )
        cred = read_b64(other, "/root/cred.blob")
        put_b64(machine, "/root/cred.blob", cred)
        machine.succeed("trust-tpm-receive --cred /root/cred.blob")
        machine.succeed("test -s /var/lib/trust/sealed/seal.priv")
        # The plaintext is nowhere on disk or in the journal.
        machine.fail("grep -r the-unseal-key /var/lib /root /etc 2>/dev/null")
        machine.fail("journalctl --no-pager | grep -q the-unseal-key")

    with subtest("the same credential cannot be received by another TPM"):
        put_b64(other, "/root/cred.blob", cred)
        other.fail("trust-tpm-receive --cred /root/cred.blob")
        other.fail("test -e /var/lib/trust/sealed/seal.priv")

    with subtest("release works in the sealed PCR state"):
        out = machine.succeed("trust-tpm-unseal")
        assert out == "the-unseal-key", f"unexpected secret: {out!r}"

    with subtest("tampered measured boot (policy PCR) blocks release"):
        machine.succeed(f"tpm2_pcrextend 13:sha256={TAMPER}")
        machine.fail("trust-tpm-unseal")

    with subtest("reboot restores the PCR state; release works again"):
        reboot(machine)
        out = machine.succeed("trust-tpm-unseal")
        assert out == "the-unseal-key"

    with subtest("lock PCR: after the lock, no process can release the key"):
        machine.succeed("trust-tpm-lock")
        machine.fail("trust-tpm-unseal")

    with subtest("reboot clears the lock"):
        reboot(machine)
        out = machine.succeed("trust-tpm-unseal")
        assert out == "the-unseal-key"

    with subtest("re-sealing needs --force"):
        machine.fail("echo x | trust-tpm-seal")
        machine.succeed("echo x | trust-tpm-seal --force")
  '';
}
