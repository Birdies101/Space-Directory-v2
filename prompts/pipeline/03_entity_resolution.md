# Prompt 03 — Entity Resolution (Deduplication) Adjudicator
**Model:** `claude-opus-5-5`. Called ONLY for pairs in the ambiguous band.
**Upstream (deterministic, in code):**
1. **Exact identifier match.** If a shared AWARD_ID, PIID, FCC_FILE, FAA_LICENSE, NORAD, or TECHPORT ID ties the candidate to an existing project, it becomes `new_evidence` automatically, no model call. If a shared UEI/CIK/domain ties it to an existing org, it is the same org.
2. **Blocking.** Compare only candidates that share a lead org (after org resolution), or whose names have trigram similarity ≥ 0.3, or whose embedding cosine is ≥ 0.80.
3. **Scoring.** score = 0.35·name_sim + 0.25·same_lead_org + 0.20·embedding_cos + 0.10·sector_match + 0.10·date_overlap.
   - score ≥ 0.92 with same lead org → auto-merge as `new_evidence`, logged, and 5% audited.
   - 0.55 ≤ score < 0.92, or any score where the lead orgs differ but the names are similar → **this prompt**.
   - score < 0.55 → treated as distinct.

Resolve organizations before projects, using the same pattern. An org variant of this prompt swaps the project fields for name/aliases/domain/HQ/identifiers/parent.

---
## SYSTEM

You decide whether two records describe the same commercial space project, applying the codebook's unit-of-analysis rules exactly.

<unit_of_analysis>
{CODEBOOK_SECTION_1}
</unit_of_analysis>

Possible verdicts:
- `same_project`: the same project. The candidate's evidence attaches to the existing record. Name differences are aliases.
- `same_project_new_phase`: the same project; the candidate describes a later phase, mission, block, or contract option. Attach as milestone/evidence.
- `related_distinct`: a genuinely separate project that should be linked (same company's other product; successor system; supplier relationship). Satisfies the split rule (≥ 2 differing dimensions).
- `different`: unrelated.
- `insufficient_information`: cannot decide. Name the single fact that would decide it.

Reasoning discipline:
- Never merge just because the lead organization is the same. Companies run several projects.
- Never split just because the names differ. Renames, codenames, and marketing names are common.
- An acquisition does not create a new project. Corporate-name differences between the two records may be explained by a parent/subsidiary relationship; check the org context.
- For `related_distinct`, list the split-rule dimensions that differ.

Think through the comparison briefly, then return JSON only.

## USER (template)
```
<existing_project>{project_json_with_aliases_orgs_identifiers_milestones_top5_evidence_notes}</existing_project>
<candidate>{candidate_extraction_json}</candidate>
<org_context>{lead_org_records_both_sides_with_parents_aliases}</org_context>
<similarity>{name_sim, embedding_cos, shared_identifiers}</similarity>
```

## OUTPUT SCHEMA
```json
{
  "verdict": "same_project | same_project_new_phase | related_distinct | different | insufficient_information",
  "confidence": 0.0,
  "differing_dimensions": ["product", "customer", "lead_org", "funding_line", "stage_progression"],
  "new_aliases": ["..."],
  "relationship_if_related": "successor | sibling_product | supplier | component_of | null",
  "deciding_fact_needed": null,
  "rationale": "≤ 60 words"
}
```

## ROUTING
- `same_project` / `same_project_new_phase` with confidence ≥ 0.85 → attach the evidence; then run prompt 05 (change detection).
- `related_distinct` / `different` with confidence ≥ 0.85 → a new project candidate goes to prompt 04.
- Anything below 0.85, or `insufficient_information` → `review_queue` item_type `merge`, with both records shown side by side.
