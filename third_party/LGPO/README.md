# LGPO.exe (not in git)

Put Microsoft's `LGPO.exe` here before building the wizard; the build embeds
it so the wizard stays one exe (decided in `docs/OPEN_QUESTIONS.md` item 3).

Download: Microsoft Security Compliance Toolkit → `LGPO.zip`. Read the
"Standalone Use Terms" PDF inside the zip: redistribution terms are
**[Uncertain]** (see OPEN_QUESTIONS 3).

Without it, the wizard uses an `LGPO.exe` placed next to `WOSetupWizard.exe`,
and otherwise the scripts' fallback (policies written straight to the
registry, not visible in gpedit, User policies reach only the current account).
