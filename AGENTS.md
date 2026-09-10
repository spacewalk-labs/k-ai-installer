# Repository Safety Invariants

- **Ownership-gated VM mutation:** Before adopting, managing, or deleting an existing VM, require
  persisted state, its immutable record ID and live record, and the guest owner marker to agree. Before
  creation, atomically journal intent; accept the result only after capturing its record ID and validating
  its guest marker. If proof is missing, mismatched, or uncertain, stop without further mutation.
- **Explicit, retryable transactions:** Lock before VM mutation and atomically persist pending work so
  interruption remains visible and retryable without duplicate mutation. Reject corrupt, unsupported, or
  ambiguous state before mutation; never guess success or repair uncertainty before verification. A
  deletion succeeds only after absence by both record ID and name is verified.
- **Secret and identifier containment:** Exclude or redact secrets and ownership identifiers across errors,
  diagnostics, logs, and exported artifacts. Persist only the ownership ledger required for safe recovery in
  mode-0600 runtime state, keep diagnostics allowlisted, and preserve scanner coverage of source, build, and
  runtime outputs.
