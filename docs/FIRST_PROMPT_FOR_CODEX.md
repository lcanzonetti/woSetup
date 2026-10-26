# First prompt to give Codex

Copy everything between the lines into Codex as the first task.

---

Read `AGENTS.md`, then `docs/PROJECT_CONTEXT.md`, both checklists in
`docs/checklists/` and both scripts in `scripts/`. Do not write code yet.

Deliver, as a pull request containing only Markdown:

1. `docs/ARCHITECTURE.md`: the proposed solution structure (projects, main
   classes, step model, state file schema, resume-after-reboot mechanism,
   how the .ps1 engine is embedded and invoked under Windows PowerShell 5.1,
   logging, elevation manifest).
2. `docs/WIZARD_FLOW.md`: every wizard step for the WATCHOUT 7 and WATCHOUT 6
   profiles, in checklist order, each marked Automated / Manual / Check,
   with the exact script phase or verification command it uses and where a
   reboot happens.
3. `docs/MILESTONES.md`: a milestone plan (M1 skeleton + state + resume,
   M2 PreUpdate/PostInstall runners with live log, M3 manual/check steps,
   M4 options UI mapped to script parameters, M5 report + packaging).
4. Answers or recommendations for each item in `docs/OPEN_QUESTIONS.md`.

Keep every `[Uncertain]` item flagged. Ask me before deviating from the
checklists or adding tweaks.

---
