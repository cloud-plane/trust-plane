# SPDX-License-Identifier: Apache-2.0
#
# Root OpenBao cluster scenario (design 4.2, 4.3, 4.5, 8):
#  - init exactly once; nodes 2 and 3 join the same Raft ring
#  - the unseal key reaches each node only through its TPM (EK-bound
#    credential) and is sealed locally; no human types it again
#  - two audit devices, root token revocation, quorum `generate-root`
#  - cold start of all nodes unseals without human input
#  - a node with a tampered measured-boot state stays sealed while the rest of
#    the cluster keeps quorum
{ self, pkgs, ... }:
let
  nodeNames = [
    "node1"
    "node2"
    "node3"
  ];
  pki = import ./lib/pki.nix {
    inherit pkgs;
    nodes = nodeNames;
  };
in
pkgs.testers.runNixOSTest {
  name = "trust-bao-cluster";

  defaults =
    { config, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 1536;
      virtualisation.tpm.enable = true;

      trust.tpmUnseal = {
        enable = true;
        policyPcrs = [ "13" ];
        lockPcr = "14";
        unsealTimeoutSeconds = 900;
      };

      trust.openbaoRoot = {
        enable = true;
        openFirewall = true;
        auditDevices = [
          {
            name = "audit-a";
            filePath = "/var/log/openbao/audit-a.log";
          }
          {
            name = "audit-b";
            filePath = "/var/log/openbao/audit-b.log";
          }
        ];
        tls = {
          certFile = "${pki}/${config.networking.hostName}.chain.pem";
          keyFile = "${pki}/${config.networking.hostName}.key";
          caFile = "${pki}/root.pem";
        };
      };

      environment.systemPackages = [
        pkgs.curl # raw HTTP to the unauthenticated generate-root endpoints
        pkgs.jq
        pkgs.e2fsprogs # chattr, to break one audit sink
      ];

      # Test-only: emulate a tampered boot chain by extending the policy PCR
      # before the unseal service runs, when the marker file exists.
      systemd.services.test-tamper = {
        wantedBy = [ "multi-user.target" ];
        before = [ "openbao-unseal.service" ];
        unitConfig.ConditionPathExists = "/var/lib/trust/tamper";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.tpm2-tools}/bin/tpm2_pcrextend 13:sha256=${
            pkgs.lib.fixedWidthString 64 "a" ""
          }";
        };
        environment.TPM2TOOLS_TCTI = "device:/dev/tpmrm0";
      };
    };

  nodes = {
    node1 = {
      trust.openbaoRoot.joinPeers = [ ]; # bootstrap node: the only one ever initialised
    };
    node2 = {
      trust.openbaoRoot.joinPeers = [ "node1" ];
    };
    node3 = {
      trust.openbaoRoot.joinPeers = [ "node1" ];
    };
    # Stands in for the ceremony workstation: no TPM needed for makecredential.
    admin =
      { ... }:
      {
        environment.systemPackages = [
          (pkgs.callPackage ../pkgs/trust-tpm-tools { })
        ];
      };
  };

  testScript = ''
    import base64
    import json

    nodes = [node1, node2, node3]
    CA = "${pki}/root.pem"

    def env(node, token=None):
        e = f"export BAO_ADDR=https://{node.name}:8200 BAO_CACERT={CA}; "
        if token:
            e += f"export BAO_TOKEN={token}; "
        return e

    def bao(node, cmd, token=None):
        return node.succeed(env(node, token) + "bao " + cmd)

    def status(node):
        # `bao status` exits 2 while sealed; parse the JSON either way.
        out = node.succeed(env(node) + "bao status -format=json || true")
        return json.loads(out)

    def read_b64(node, path):
        return node.succeed(f"base64 -w0 {path}").strip()

    def put_b64(node, path, data):
        node.succeed(f"echo {data} | base64 -d > {path}")

    def deliver_unseal_key(node, key):
        """Ceremony step 4: EK-bound delivery, sealed locally on the node."""
        node.succeed("trust-tpm-enroll /root/enroll")
        put_b64(admin, "/root/ek.pub", read_b64(node, "/root/enroll/ek.pub"))
        name = node.succeed("cat /root/enroll/ak.name.hex").strip()
        admin.succeed(
            f"printf %s '{key}' | trust-tpm-makecredential --ek /root/ek.pub --name {name} --out /root/cred.blob"
        )
        put_b64(node, "/root/cred.blob", read_b64(admin, "/root/cred.blob"))
        node.succeed("trust-tpm-receive --cred /root/cred.blob")

    def wait_unsealed(node):
        node.wait_until_succeeds(env(node) + "bao status -format=json | jq -e '.sealed == false'", timeout=600)

    def assert_ring(token):
        # Every node must see the same three-voter ring. Joiners start as
        # non-voters until autopilot promotes them after they catch up, so
        # wait for the ring to settle on each node.
        for n in nodes:
            n.wait_until_succeeds(
                env(n, token)
                + "bao operator raft list-peers -format=json"
                + " | jq -e '.data.config.servers | length == 3 and all(.[]; .voter)'",
                timeout=300,
            )

    start_all()
    for n in nodes:
        n.wait_for_unit("openbao.service")
        n.wait_for_open_port(8200)

    with subtest("fresh nodes are uninitialised and sealed"):
        for n in nodes:
            s = status(n)
            assert s["initialized"] is False and s["sealed"] is True, s

    with subtest("initialise exactly once, on the bootstrap node"):
        init = json.loads(bao(node1, "operator init -key-shares=1 -key-threshold=1 -format=json"))
        unseal_key = init["unseal_keys_b64"][0]
        root_token = init["root_token"]
        # The other nodes were not initialised by this.
        assert status(node2)["initialized"] is False

    with subtest("unseal key is delivered to each TPM and sealed locally"):
        for n in nodes:
            deliver_unseal_key(n, unseal_key)
        admin.succeed("rm -f /root/cred.blob /root/ek.pub")

    with subtest("units pick up the sealed key and unseal without a human"):
        for n in nodes:
            wait_unsealed(n)
            n.wait_for_unit("openbao-unseal.service")

    with subtest("all three nodes form one Raft ring"):
        assert_ring(root_token)
        for n in nodes:
            assert status(n)["cluster_id"] == status(node1)["cluster_id"]

    with subtest("lock PCR: the unseal key cannot be released again until reboot"):
        for n in nodes:
            n.fail("trust-tpm-unseal")

    with subtest("two audit devices record requests; a failing sink does not stop the cluster"):
        # node1 is the leader at this point, so it handles (and audits) locally.
        # `audit list -format=json` returns the devices at the top level.
        devices = json.loads(bao(node1, "audit list -format=json", root_token))
        assert "audit-a/" in devices and "audit-b/" in devices, devices
        bao(node1, "token lookup", root_token)
        for f in ("audit-a", "audit-b"):
            node1.succeed(f"grep -q '\"type\":\"request\"' /var/log/openbao/{f}.log")
        a1 = node1.succeed("stat -c %s /var/log/openbao/audit-a.log").strip()
        b1 = node1.succeed("stat -c %s /var/log/openbao/audit-b.log").strip()
        # Break one sink: the device keeps its open fd, but the immutable
        # flag makes the kernel refuse further writes to the file.
        node1.succeed("chattr +i /var/log/openbao/audit-b.log")
        bao(node1, "token lookup", root_token)
        node1.succeed(f"test $(stat -c %s /var/log/openbao/audit-a.log) -gt {a1}")
        node1.succeed(f"test $(stat -c %s /var/log/openbao/audit-b.log) -eq {b1}")
        # Restore writability so later reboots can re-enable both devices.
        node1.succeed("chattr -i /var/log/openbao/audit-b.log")

    with subtest("root token is revoked; generate-root needs the unseal key"):
        bao(node1, "token revoke -self", root_token)
        node1.fail(env(node1, root_token) + "bao token lookup")
        # No token exists any more, so the CLI cannot drive generate-root:
        # the unauthenticated /v1/sys/generate-root endpoints (opt-in per
        # listener, see openbao-root.nix) take the unseal key directly.
        # The returned encoded token is the token XORed with the returned
        # OTP, base64-encoded without padding.
        gr = json.loads(node1.succeed(
            f"curl -s --cacert {CA} -X PUT "
            "https://node1:8200/v1/sys/generate-root/attempt"
        ))
        gr = gr.get("data", gr)
        nonce, otp = gr["nonce"], gr["otp"]
        body = f'{{"key":"{unseal_key}","nonce":"{nonce}"}}'
        upd = json.loads(node1.succeed(
            f"curl -s --cacert {CA} -X PUT "
            f"https://node1:8200/v1/sys/generate-root/update -d '{body}'"
        ))
        upd = upd.get("data", upd)
        assert upd["complete"] is True, upd
        encoded = upd["encoded_token"]
        raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4))
        assert len(raw) == len(otp), (len(raw), len(otp))
        new_root = bytes(a ^ b for a, b in zip(raw, otp.encode())).decode()
        bao(node1, "token lookup", new_root)
        root_token = new_root

    with subtest("cold start: all nodes crash and come back unsealed by themselves"):
        # sync before the hard crash: a SIGKILLed QEMU drops its writeback
        # cache, so anything the guest has not yet barrier-flushed to the
        # host disk is lost; sync makes committed data durable first.
        for n in nodes:
            n.succeed("sync")
        for n in nodes:
            n.crash()
        for n in nodes:
            n.start()
        for n in nodes:
            n.wait_for_unit("openbao.service")
        for n in nodes:
            wait_unsealed(n)
        assert_ring(root_token)

    with subtest("losing a voter keeps quorum; the ring heals when it returns"):
        node1.succeed("sync")
        node1.crash()
        for n in (node2, node3):
            n.wait_until_succeeds(
                env(n) + "bao status -format=json | jq -e '.sealed == false and .leader_address'",
                timeout=120,
            )
        bao(node2, "token lookup", root_token)
        node1.start()
        node1.wait_for_unit("openbao.service")
        wait_unsealed(node1)
        node1.wait_for_unit("openbao-unseal.service")
        assert_ring(root_token)

    with subtest("a node with a tampered boot state stays sealed, quorum survives"):
        # sync before the hard crash: ext4's commit interval would otherwise
        # lose the just-created file and the marker would not survive reboot.
        node3.succeed("touch /var/lib/trust/tamper && sync")
        node3.crash()
        node3.start()
        node3.wait_for_unit("openbao.service")
        node3.wait_for_unit("test-tamper.service")
        node3.sleep(40)
        assert status(node3)["sealed"] is True
        node3.fail("systemctl is-active openbao-unseal.service")
        for n in (node1, node2):
            assert status(n)["sealed"] is False
        bao(node1, "token lookup", root_token)

    with subtest("clean boot state unseals the node again"):
        node3.succeed("rm /var/lib/trust/tamper && sync")
        node3.crash()
        node3.start()
        wait_unsealed(node3)
        assert_ring(root_token)
  '';
}
