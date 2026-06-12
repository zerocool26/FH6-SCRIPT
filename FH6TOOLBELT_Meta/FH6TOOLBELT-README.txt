FH6TOOLBELT
===========
Created/Updated: 06/12/2026 06:23:03
Location: C:\Users\boss\Downloads\FH6TOOLBELT
Current Companion Doctor: v5.5

This folder consolidates the FH6 Companion Doctor project files, SaveDoctor files,
Companion Doctor generated data folders, portable bundles, reports, logs, support
packages, snapshots, sessions, telemetry logs, manifest/settings, CrashScope,
Stability workbench, Experiment Lab outputs, Crash Matrix outputs, CrashOps
Center outputs, and the Codex workspace used to build the tool.

Layout:
  Run-FH6-CompanionDoctor.cmd  Root launcher for Tools\FH6-CompanionDoctor.ps1.
  Run-FH6-SaveDoctor.cmd       Root launcher for Tools\FH6-SaveDoctor.ps1.
  Tools                        Main scripts, launchers, README files, manifest/settings.
  CompanionDoctorData          Backups, logs, reports, support packages, snapshots, sessions, telemetry, portable bundles, CrashScope/Stability/Experiment/Matrix/Ops data.
  CompanionDoctorData\CrashScope_Universal
                               Universal game/app crash reports, Crash Intel exports, Stability exports, and command playbooks.
  CompanionDoctorData\CrashExperimentLab
                               Evidence quality exports, one-variable experiment plans, and attempt journal artifacts.
  CompanionDoctorData\CrashMatrix
                               System-wide app crash leaderboards, shared fault clusters, and root-cause signal reports.
  CompanionDoctorData\CrashOpsCenter
                               Readiness scoreboards, capture plans, decision boards, command queues, and tool readiness exports.
  Consolidated_Outside_FH6_Project_Files
                               Project-related folders moved from the top level of Downloads so FH6TOOLBELT is the single project folder.
  CodexWorkspace               Current Codex workspace copy.
  FH6TOOLBELT_Meta             Inventory and this summary.

v5.5 highlights:
  - Ops Center tab adds an evidence operations layer for FH6 and all recent app crashes.
  - Readiness scoreboard checks crash evidence, fingerprint strength, evidence quality, dump readiness, tool coverage, system-wide Matrix signals, security blocks, support-package freshness, and experiment journal coverage.
  - Capture plan recommends baseline support packages, fingerprint control runs, WER LocalDumps, ProcDump, WPR, Process Monitor, DISM/SFC, clean boot, and one-variable experiments based on current evidence.
  - Decision board explains whether to treat the crash as FH6-specific or system-wide, when to capture stronger evidence, and when escalation evidence is coherent enough.
  - Command queue generates reviewable commands for snapshots, DxDiag, WER LocalDumps, ProcDump, WPR, ProcMon, wevtutil export, DISM, SFC, and WinDbg without silently running them.
  - CrashOps exports text, JSON, CSV readiness, CSV capture plan, CSV decisions, CSV commands, and CSV tool inventory into CompanionDoctorData\CrashOpsCenter.
  - Reports, support packages, state snapshots, self-test, manifest, Dashboard quick action, and no-GUI universal output include CrashOps artifacts.
  - Official research coverage includes Microsoft crash triage guidance, WER LocalDumps, user-mode dump analysis, WinDbg, WPR command-line tracing, Process Monitor, Sysinternals, DISM/SFC image repair, TSS data collection, Kernel-Power Event ID 41, GPU TDR, ReliabilityRecords, Defender ASR events, Controlled Folder Access, clean boot isolation, and Windows Memory Diagnostic.

Latest portable bundle:
  C:\Users\boss\Downloads\FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_PortableBundles\FH6_CompanionDoctor_Portable_20260609_175655.zip

Counts:
  Folders: 41
  Files: 147
  Total bytes: 54264196

Notes:
  Game install files were not copied or modified.
  CrashScope, Crash Intel, Stability, Experiment Lab, Crash Matrix, and CrashOps Center read Windows evidence and generate reports/commands/journals; they do not inject, read memory, automate gameplay, edit saves for advantage, or modify game installs.
  On 06/12/2026, older project-output folders that were still directly under Downloads were moved into Consolidated_Outside_FH6_Project_Files. Original folder names were preserved.
