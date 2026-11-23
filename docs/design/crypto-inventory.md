---
title: "Root of Trust: FIPS and Crypto Inventory"
linkTitle: "Crypto Inventory"
weight: 8
---

Part of the [Root of Trust](../) design. Section numbers are global across the
parts of this design.

## 9. FIPS and crypto inventory

- keystone-rs under the `fips` feature uses the validated module and random
  module-generated IVs only in `fips` builds; default builds keep deterministic
  nonces. This design changes neither.
- **OpenBao Transit is outside the validated boundary.** With
  `kek_provider = "transit"` the KEK lives in the root OpenBao's process memory,
  weaker than the PKCS#11 provider's guarantee that the KEK is never in memory.
  Deployments that must claim FIPS 140-3 use the **PKCS#11** KEK provider on a
  validated HSM and may still use the OpenBao cluster for non-FIPS-scoped
  consumers. The `transit` provider records this deviation in the keystone-rs
  crypto inventory in the same change that adds it. An HSM-sealed OpenBao
  barrier narrows the gap.
