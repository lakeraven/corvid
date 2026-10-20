# ADR 0008: Keyed verification snapshot fingerprints

**Status:** Proposed
**Date:** 2026-10-20

## Context

`TribalEligibilityService` stores `verification_snapshot_hash` on each `PrcEligibilityDecision` so an auditor can confirm that a later re-check saw the same adapter responses. The value is a plain SHA256 of `JSON(enrollment, identity, residency)`.

The snapshot does not contain SSN last-4 or DOB values. It contains presence booleans (`ssn_present`, `dob_present`, `birthplace_present`), tribe enrollment fields (tribe code, member status, confidence), and residency fields (`on_reservation`, address, `verified_at`), which are enumerable/low-entropy and identifying. Anyone holding a database copy can hash guesses until one matches and recover the inputs the digest was meant to stand in for. That works against ADR 0003, which says a corvid dump must reveal no PHI.

The adapter responses themselves are not retained. The fingerprint is the only record of what the source returned.

## Decision

1. **Fingerprints are HMAC-SHA256 under a host-supplied key.** `Corvid::SnapshotFingerprint.compute` returns the hex digest and the key version. It never falls back to an unkeyed SHA256.

2. **Hosts load versioned keys from a secret store and pass them through `Corvid.configure`.** Each key is a String of at least 32 bytes. `Configuration#inspect`, `#as_json`, `#to_json`, and `#to_yaml` list key versions only and do not reveal key material.

   ```ruby
   Corvid.configure do |c|
     c.verification_snapshot_keys = {
       "2026-10" => secret_store.fetch("corvid/verification-snapshot/2026-10")
     }
     c.verification_snapshot_key_version = "2026-10"
   end
   ```

3. **The HMAC input is canonical JSON.** Hashes are copied with keys converted to strings and sorted, recursively. Arrays are mapped recursively. `Time`, `DateTime`, and `ActiveSupport::TimeWithZone` become UTC ISO8601 with six fractional digits. `Date` becomes `iso8601`. Other values are left unchanged, then `JSON.generate` serializes the copy. `compute` and `matches?` both use that form, so key order and time zone do not change the digest.

4. **A usable version is a String or Symbol.** It must be non-blank after strip and at most 64 characters. `compute` returns that version as a String (`to_s`). Lookup compares names with `to_s` and does not follow a Hash default or default proc. A number, a blank, or a name longer than 64 characters is unusable.

5. **The row stores the key version next to the digest.** `corvid_prc_eligibility_decisions.verification_snapshot_key_version` is a nullable string. The presence check applies only when a hash is being set or changed, so a legacy row (hash, nil version) can be updated. A hash written from now on must name its version. The length check uses the same 64-character limit as the fingerprint.

6. **Rotation is add-and-switch.** Add the new key under a new version, point `verification_snapshot_key_version` at it, and keep the previous key until the retention window for rows that name it has passed. Then retire the old key. `matches?(hash:, version:, payload:)` verifies with the key for the row's version, using a constant-time compare. A blank version, a missing or invalid key, or an error while building the digest returns `nil` (cannot verify), not `false`.

7. **No usable key, or a digest that cannot be computed, means no fingerprint.** If the current version is unusable, the key is missing, the key is not a String, or the key is shorter than 32 bytes, both columns are stored as `nil`. Serialization and HMAC errors do the same: `compute` logs a warning that names the error class and does not include the payload or the key, then returns `[nil, nil]`. The eligibility decision is still recorded. An unkeyed digest is never written (fail closed).

8. **Legacy plain-SHA256 rows are left as-is.** Their version stays `nil`. `matches?` returns `nil` for them. The API serves `verification_snapshot_hash` only when `verification_snapshot_key_version` is present, so a legacy row returns null for the hash. There is no backfill: the inputs were not retained (ADR 0003), so the engine cannot recompute an HMAC for those rows.

Synthetic check, not a real patient:

```ruby
payload = {
  enrollment: { tribe_code: "EXAMPLE", member_status: "enrolled", confidence: "verified" },
  identity: { ssn_present: true, dob_present: true, birthplace_present: false },
  residency: { on_reservation: true, address: "1 Example Road", verified_at: "2026-05-16T12:00:00.000000Z" }
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
- Legacy rows stay unverifiable. A nil result from `matches?` means "cannot check," not "mismatch." The API does not serve those hashes.

### Alternatives considered

- **Keep plain SHA256.** Rejected. The input space is small enough to dictionary-attack, and the digest would keep leaking what ADR 0003 says a dump must not reveal.
- **Store the pepper in the database.** Rejected. A dump would include the secret, which is the attack this change closes.
- **Encrypt and store the adapter responses.** Rejected. That retains PHI-derived inputs in corvid, the opposite of ADR 0003. The fingerprint exists so those inputs do not have to be kept.
- **Backfill legacy rows to HMAC.** Rejected. The inputs were not retained, so there is nothing to re-hash. Rewriting a plain SHA256 as if it were an HMAC would make the column lie.

## Open questions

- **(a) Scrubbing legacy hashes at rest.** Legacy plain-SHA256 hashes remain dictionary-attackable in a dump. Whether to scrub them is open. Scrubbing is irreversible: the inputs were not retained, so a scrubbed row cannot be verified later.
- **(b) Volatile `verified_at`.** The fingerprinted payload includes adapter `verified_at`, which adapters may set to the call time, so `matches?` cannot confirm a later re-check saw identical data unless volatile fields are excluded. That is pre-existing behaviour, left for a maintainer decision.

## References

- #629 Audit fingerprints of adapter responses should use a keyed hash
- ADR 0003 PHI tokenization
