FH6TOOLBELT
===========
Created/Updated: 06/09/2026 01:39:12
Location: C:\Users\boss\Downloads\FH6TOOLBELT
Current Companion Doctor: v5.2

This folder consolidates the FH6 Companion Doctor project files, SaveDoctor files,
Companion Doctor generated data folders, portable bundles, reports, logs, support
packages, snapshots, sessions, telemetry logs, manifest/settings, CrashScope and
Stability workbench outputs, and the Codex workspace used to build the tool.

Layout:
  Run-FH6-CompanionDoctor.cmd  Root launcher for Tools\FH6-CompanionDoctor.ps1.
  Run-FH6-SaveDoctor.cmd       Root launcher for Tools\FH6-SaveDoctor.ps1.
  Tools                        Main scripts, launchers, README files, manifest/settings.
  CompanionDoctorData          Backups, logs, reports, support packages, snapshots, sessions, telemetry, portable bundles, CrashScope/Stability data.
  CompanionDoctorData\CrashScope_Universal
                               Universal game/app crash reports, Crash Intel exports, Stability exports, and command playbooks.
  CodexWorkspace               Current Codex workspace copy.
  FH6TOOLBELT_Meta             Inventory and this summary.

v5.2 highlights:
  - Stability tab adds a unified evidence timeline across app crashes, WER, Reliability Monitor, GPU/TDR, Defender security events, recent changes, FH6 reports, and user-data timestamps.
  - Evidence Insights and Generated Runbook turn the timeline into ranked next moves with risk and success checks.
  - Stability exports write text, JSON, and CSV artifacts into CrashScope_Universal.
  - Support packages, state snapshots, reports, self-test, and no-GUI universal output include Stability artifacts.
  - Read-only per-run caching keeps advanced evidence scans from re-querying Windows logs repeatedly inside one action.
  - Root and Tools launchers remain self-contained inside FH6TOOLBELT, and portable output stays in FH6TOOLBELT\CompanionDoctorData.

Latest portable bundle:
  C:\Users\boss\Downloads\FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_PortableBundles\FH6_CompanionDoctor_Portable_20260609_013648.zip

Counts:
  Folders: 26
  Files: 115
  Total bytes: 48064117

Notes:
  Game install files were not copied or modified.
  CrashScope, Crash Intel, and Stability read Windows evidence and generate reports/commands; they do not inject, read memory, automate gameplay, edit saves for advantage, or modify game installs.
