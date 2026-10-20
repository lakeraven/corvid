# ADR 0008: Keyed verification snapshot fingerprints

**Status:** Proposed
**Date:** 2026-10-20

## Context

`TribalEligibilityService` stores `verification_snapshot_hash` on each `PrcEligibilityDecision` so an auditor can confirm that a later re-check saw the same adapter responses. The value is a plain SHA256 of `JSON(enrollment, identity, residency)`.

Those responses carry low-entropy, PHI-derived fields. An SSN last-4 has 10,000 candidates, a date of birth is a small calendar, and tribe codes and facility kinds are enumerable. Anyone holding a database copy can hash guesses until one matches and recover the inputs the digest was meant to stand in for. That works against ADR 0003, which says a corvid dump must reveal no PHI.

The adapter responses themselves are not retained. The fingerprint is the only record of what the source returned.

## Decision

1. **Fingerprints are HMAC-SHA256 under a host-supplied key.** `Corvid::SnapshotFingerprint.compute` returns `OpenSSL::HMAC.hexdigest("SHA256", key, JSON.generate(payload))` and the key version. It never falls back to an unkeyed SHA256.

2. **Hosts load versioned keys from a secret store and pass them through `Corvid.configure`.** Each key is a String of at least 32 bytes. `Configuration#inspect` lists key versions only and does not reveal key material.

   ```ruby
   Corvid.configure do |c|
     c.verification_snapshot_keys = {
       "2026-10" => secret_store.fetch("corvid/verification-snapshot/2026-10")
     }
     c.verification_snapshot_key_version = "2026-10"
   end
   ```

3. **The row stores the key version next to the digest.** `corvid_prc_eligibility_decisions.verification_snapshot_key_version` is a nullable string. A hash written from now on must name its version (`presence: true` when the hash is present). The check runs on save, so a legacy row still loads.

4. **Rotation is add-and-switch.** Add the new key under a new version, point `verification_snapshot_key_version` at it, and keep the previous key until the retention window for rows that name it has passed. Then retire the old key. `matches?(hash:, version:, payload:)` verifies with the key for the row's version, using a constant-time compare. A blank version, or a missing or invalid key, returns `nil` (cannot verify), not `false`.

5. **No key configured means no fingerprint.** If the current version is blank, the key is missing, the key is not a String, or the key is shorter than 32 bytes, both columns are stored as `nil`. The eligibility decision is still recorded. An unkeyed digest is never written (fail closed).

6. **Legacy plain-SHA256 rows are left as-is.** Their version stays `nil`. `matches?` returns `nil` for them. There is no backfill: the inputs were not retained (ADR 0003), so the engine cannot recompute an HMAC for those rows.

Synthetic check, not a real patient:

```ruby
payload = {
  enrollment: { tribe_code: "EXAMPLE" },
  identity: { ssn_last4: "0000" },
  residency: {}
}
digest, version = Corvid::SnapshotFingerprint.compute(payload)
Corvid::SnapshotFingerprint.matches?(hash: digest, version: version, payload: payload)
# => true
```

## Consequences

### Positive

- A database copy alone is not enough to test guesses. The key stays in the host secret store.
- Rotation does not invalidate older rows while the previous key is still configured.
- Forgetting to configure a key fails closed: no unkeyed digest is written, and the decision itself is still saved.

### Negative

- Hosts that want fingerprints must configure a key of at least 32 bytes. Until they do, new rows have a nil hash.
- Losing a key makes fingerprints produced with that version unverifiable. It does not make them wrong, and it does not change the recorded decision.
- Legacy rows stay unverifiable. A nil result from `matches?` means "cannot check," not "mismatch."

### Alternatives considered

- **Keep plain SHA256.** Rejected. The input space is small enough to dictionary-attack, and the digest would keep leaking what ADR 0003 says a dump must not reveal.
- **Store the pepper in the database.** Rejected. A dump would include the secret, which is the attack this change closes.
- **Encrypt and store the adapter responses.** Rejected. That retains PHI-derived inputs in corvid, the opposite of ADR 0003. The fingerprint exists so those inputs do not have to be kept.
- **Backfill legacy rows to HMAC.** Rejected. The inputs were not retained, so there is nothing to re-hash. Rewriting a plain SHA256 as if it were an HMAC would make the column lie.

## References

- #629 Audit fingerprints of adapter responses should use a keyed hash
- ADR 0003 PHI tokenization
