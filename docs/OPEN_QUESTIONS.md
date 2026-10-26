# Open questions

Decide these with the owner before or during the first milestones.

1. **Tech stack**: C# .NET 8 WPF single-file exe (proposed) vs PowerShell WPF + PS2EXE.
2. **Engine**: keep running the two .ps1 scripts (embedded) first, port to C# later? (proposed: yes)
3. **LGPO.exe**: bundle (check Microsoft licence terms), ask the user for its
   path, or write Registry.pol natively?
4. **WinUtil step**: launch WinUtil and show the tick list (needs internet:
   `irm christitus.com/win | iex`), or re-implement the selected tweaks natively?
5. **Code signing**: certificate available? Unsigned elevated exes trigger
   SmartScreen and AV warnings.
6. **Single exe for WO6 and WO7** with a profile choice at start (proposed), or two builds?
7. **Machine profiles**: save/load an options profile (role, paths, switches)
   per show/client to reuse on twin servers?
8. **Report**: generate a per-machine HTML/PDF build report (what was applied,
   warnings, versions) for the client file?
9. **Diagnostics page**: include the HAP-stutter logging recipe (nvidia-smi +
   logman) as a "record performance during soak test" tool?
10. **Untested behaviour** to verify on hardware: UserPreferencesMask value,
    NotifyOnUsbErrors, LGPO merge behaviour, WaaSMedic re-enabling wuauserv,
    DisableAntiSpyware visibility in gpedit on 25H2.
