# WATCHOUT Server Setup Wizard

GUI wizard (Windows .exe) that guides and automates the preparation of
Dataton WATCHOUT 6 / WATCHOUT 7 display servers and production PCs on
Windows 11 Pro 64-bit 25H2.

Status: **planning**. The procedure and automation already exist:

- `docs/checklists/` – field-tested build checklists (WO6, WO7)
- `scripts/` – `WO6-Setup.ps1`, `WO7-Setup.ps1` (PreUpdate / PostInstall)
- `docs/PROJECT_CONTEXT.md` – decision log and hardware/OS findings
- `docs/OPEN_QUESTIONS.md` – decisions still to make
- `AGENTS.md` – instructions for coding agents

The scripts need `LGPO.exe` (Microsoft Security Compliance Toolkit) next to
them and must run elevated under Windows PowerShell 5.1.

Planning documents (proposal, awaiting owner review):

- `docs/ARCHITECTURE.md` – solution structure, step model, state file, resume, engine invocation, logging
- `docs/WIZARD_FLOW.md` – every wizard step for WO7 and WO6, in checklist order
- `docs/MILESTONES.md` – M1–M5 plan with acceptance criteria
