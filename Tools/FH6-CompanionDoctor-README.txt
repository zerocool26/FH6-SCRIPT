FH6 Companion Doctor v5.5
=======================

Files:
  FH6-CompanionDoctor.ps1
  Run-FH6-CompanionDoctor.cmd

Recommended launch:
  Double-click FH6TOOLBELT\Run-FH6-CompanionDoctor.cmd

Purpose:
  This is an external Forza Horizon 6 companion and diagnostics tool. It is built
  to help with maintenance, crash analysis, backups, safe cleanup, telemetry,
  device checks, launch preflight, and support-package creation.

Hard safety boundaries:
  - Does not modify the Steam game install folder.
  - Does not modify forzahorizon6.exe.
  - Does not inject into the game.
  - Does not read or write game memory.
  - Does not edit saves for cars, credits, progression, unlocks, or advantages.
  - Does not automate gameplay, Auction House activity, menus, or controller input.

Tabs:
  Dashboard:
    The first-screen control center. Shows game/process state, health warning
    count, latest crash pattern, save/cache footprint, telemetry state, ranked
    expert recommendations, recent evidence timeline, and quick actions for
    refresh, runbook, Deep Fresh, tracked launch, support package, telemetry
    check, Steam Cloud steps, Crash Watch, action plan, Ops Center, and reports.

  Guided Fix:
    Converts current evidence into a prioritized workflow. It can export the
    plan, copy the top action, build a support package, start a tracked launch,
    or run the confirmed Deep Fresh user-data workflow.

  CrashScope:
    Universal crash triage for FH6 and other games/apps. It scans Windows
    Application Error, Windows Error Reporting, and Application Hang events,
    groups crash fingerprints by app/code/module, maps common exception codes
    into a taxonomy, checks evidence-tool readiness, inspects LocalDumps config,
    generates LocalDumps/ProcDump/WPR/DISM/SFC command playbooks, and exports
    target-specific reports.

  Crash Intel:
    Evidence-weighted analysis for FH6 or any target executable. It scores
    likely root-cause families, builds a crash heatmap, and correlates the crash
    anchor with recent drivers, Windows updates, software installs, GPU/TDR
    events, capture-stack settings, overlays/hooks, reliability records, runtime
    prerequisites, and evidence gaps.

  Stability:
    Bigger-picture crash workbench for FH6, any target executable, or all recent
    app crashes. It builds a unified timeline from Application Error/WER,
    Reliability Monitor, GPU/TDR, Defender ASR/Controlled Folder Access,
    recent system changes, FH6 local reports, and user-data timestamps. It also
    creates evidence insights and a step-by-step runbook with risk and success
    checks.

  Experiments:
    Controlled crash-fix experiment lab. It scores evidence quality, generates
    a one-variable-at-a-time test plan, logs Started/Crashed/Stable attempts,
    and exports quality/plan/journal artifacts so every fix attempt is tied to
    a fingerprint, evidence score, and outcome.

  Matrix:
    Universal crash matrix for the whole PC. It ranks all crashing apps, groups
    shared code/module signature clusters, and surfaces system-wide signals such
    as multi-app spread, repeated memory-fault signatures, GPU/TDR evidence,
    security enforcement blocks, recent driver/update correlation, dump evidence
    gaps, and advanced-tooling gaps.

  Ops Center:
    Crash operations workbench for deciding what evidence to capture next. It
    scores readiness, generates a capture plan, builds a decision board, checks
    advanced tool availability, and produces reviewable commands for snapshots,
    DxDiag, WER LocalDumps, ProcDump, WPR, ProcMon, event-log export, DISM/SFC,
    and WinDbg. It does not run system-level commands automatically.

  Health:
    Checks Gaming Services, Steam install path length, Steam manifest, Windows,
    memory, GPUs, storage, conflict processes, and latest crash state.

  Saves:
    Backs up, renames, deletes, restores, and monitors only FH6 local user data,
    cache/settings, and crash report roots. Backup is on by default. Dry Run is
    available. The tool refuses to touch the actual game install.

  Crash Lab:
    Reads FH6 local PreCrashReport.xml folders and Windows Event Viewer crash
    events for forzahorizon6.exe.

  Telemetry:
    Listens for FH6's official Data Out UDP telemetry. In FH6, configure:
      Settings > HUD and Gameplay > Data Out: On
      Data Out IP Address: 127.0.0.1
      Data Out IP Port: the port shown in the Telemetry tab, default 5606
    This is one-way data from the game to the tool. The tool sends nothing back.

  Devices:
    Lists USB/HID/controller/wheel-related devices and gives wheel setup advice.

  Launch:
    Runs a preflight scan, opens Steam Cloud instructions, opens the install
    folder, and can launch FH6 through Steam's steam://run URI.

  Reports:
    Exports a detailed text report or a support package zip including DxDiag,
    health data, inventory, crash events, crash report metadata, device data,
    Stability workbench artifacts, Experiment Lab artifacts, Crash Matrix
    artifacts, CrashOps artifacts, and tool logs.

Project-contained folder layout:
  FH6TOOLBELT\Tools
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_Backups
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_Reports
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_SupportPackages
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_Logs
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_Telemetry
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_Snapshots
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_Sessions
  FH6TOOLBELT\CompanionDoctorData\FH6_CompanionDoctor_PortableBundles
  FH6TOOLBELT\CompanionDoctorData\CrashScope_Universal
  FH6TOOLBELT\CompanionDoctorData\CrashExperimentLab
  FH6TOOLBELT\CompanionDoctorData\CrashMatrix
  FH6TOOLBELT\CompanionDoctorData\CrashOpsCenter

Persistent settings:
  FH6_CompanionDoctor_Settings.json
  Stores telemetry port, CSV logging preference, backup/dry-run choices, monitor
  interval, monitor mode, and last selected tab.

v3.1 additions:
  - State Snapshot buttons in Launch and Reports.
  - Automatic snapshot before Preflight + Launch.
  - Steam log matching for FH6 app ID, cloud, sync, content, and appinfo clues.
  - Steam log and conflict-process sections in text reports/support packages.
  - Support packages now include state-snapshot JSON/text, conflict-process JSON,
    and Steam log match JSON.
  - GUI remembers practical settings between runs.

v3.2 expert additions:
  - Crash Signature Analysis groups repeated crash signatures and recommends the
    next expert troubleshooting sequence.
  - WER report discovery for FH6 Windows Error Reporting folders.
  - Xbox/Gaming Services service status checks.
  - Visual C++ Redistributable inventory.
  - Media Foundation presence check for FH601-style runtime issues.
  - Snapshot Diff compares the two latest state snapshots.
  - Support packages now include WER reports, runtime/service details, conflict
    process JSON, and crash-signature-analysis.txt.

v3.3 expert additions:
  - Expert Recommendation Runbook ranks next actions based on actual evidence.
  - Event Timeline correlates crashes, FH6 reports, WER folders, Steam logs, and
    save/cache writes by timestamp.
  - Startup/logon inventory shows background programs that may survive reboots.
  - Process mitigation inventory captures Windows exploit-protection context.
  - Redacted Summary exports a privacy-reduced report for sharing.
  - Support packages now include event-timeline, expert-recommendations,
    startup-programs, and process-mitigations artifacts.

v3.4 expert additions:
  - Tracked Launch Sessions create a before snapshot, launch FH6 through Steam,
    watch for process exit, then create after/diff/correlation/session reports.
  - Latest Crash Correlation shows evidence within a +/-10 minute window around
    the newest FH6 crash.
  - Driver Inventory captures display/HID/USB/media/system driver metadata.
  - Read-only Install Audit checks Steam manifest, executable metadata, signature,
    path length, and recent top-level install timestamps without modifying files.
  - Telemetry Port Preflight checks whether the selected Data Out UDP port is
    available before listening.
  - Support packages now include driver inventory, read-only install audit,
    latest-crash correlation, and telemetry port preflight artifacts.

v3.5 expert additions:
  - Windows Gaming Settings audit for Game Mode, Game Bar, capture stack, HAGS,
    and MPO-related registry state.
  - Power/Thermal audit for active power scheme, battery state, and CPU inventory.
  - Xbox app/package inventory for Gaming Services, Xbox app, Store, Identity
    Provider, overlay, and purchase app.
  - Path Permission audit tests FH6 user/cache/tool output roots with temporary
    probe files, never the game install.
  - Backup Integrity audit checks backup zip readability and manifest presence.
  - Expert recommendations now factor capture settings, package availability,
    path permissions, and backup integrity into the runbook.

v3.6 expert additions:
  - Reliability Monitor record inventory for FH6-related Windows reliability data.
  - Display/GPU topology audit for GPU, monitor, resolution, refresh, and driver
    context.
  - Windows graphics preference audit for FH6-specific GPU preference entries.
  - App compatibility layer audit for forced compatibility/admin/fullscreen flags.
  - Security product inventory from Windows Security Center.
  - Expert recommendations now factor compatibility flags, graphics preferences,
    Reliability Monitor records, and visible security products into the runbook.

v4.0 legitimacy additions:
  - Self-Test verifies parser, collectors, telemetry port, snapshot writer, and
    safety audit status.
  - Safety Audit scans the tool for forbidden memory/injection/input/game-install
    modification patterns and documents the safety boundary.
  - Manifest writes SHA256 hashes for tool files plus official references and
    safety-audit output.
  - Official References panel lists the Forza Support pages this tool is designed
    around.
  - Portable Bundle creates a zip with the tool, launcher, README, manifest,
    official references, safety audit, and self-test output.
  - Support packages include manifest, official references, self-test, and safety
    audit artifacts.

v4.1 GUI/design additions:
  - New Dashboard first-screen with status tiles, top action, latest crash,
    save/cache footprint, ranked recommendations, and evidence timeline.
  - Live bottom status bar for game process, latest crash, telemetry listener,
    save monitor, tracked launch session, and safety boundary.
  - Improved visual styling for buttons, tables, logs, save inventory risk rows,
    and warning/OK/priority row coloring.
  - Hover help for the main actions so risky workflows explain what they do
    before you click.
  - Refresh All updates health, saves, crashes, devices, preflight, dashboard,
    and global status together.

v4.2 advanced workflow additions:
  - Guided Fix tab ranks evidence-based next steps across support evidence,
    conflict isolation, Windows capture settings, user-data refresh, runtimes,
    crash fingerprints, and escalation.
  - Crash Fingerprints groups FH6 crash events by event name, exception code,
    and module to show whether the same failure pattern survives each change.
  - Crash Watch monitors for new FH6 crash evidence and writes a detection
    report plus state snapshot; optional auto-package builds a support zip.
  - Exports, snapshots, redacted summaries, and support packages now include
    guided workflow and crash-fingerprint artifacts.

v5.0 CrashScope and portability additions:
  - Portable-aware output: when launched from FH6TOOLBELT\Tools, reports, logs,
    snapshots, sessions, telemetry, bundles, and CrashScope exports stay inside
    FH6TOOLBELT\CompanionDoctorData.
  - CrashScope tab generalizes crash triage beyond FH6 to any target executable
    or all recent app crashes.
  - Universal crash parser reads Application Error, Windows Error Reporting,
    Application Hang, and WER report folders.
  - Universal fingerprints group app/event/code/module signatures and map common
    codes such as 0xc0000005, 0xc0000409, 0xc0000374, 0xe06d7363, 0xc0000142,
    0xc000007b, 0xc0000135, DXGI 0x887A faults, and GPU/kernel patterns.
  - CrashScope command playbooks generate reviewable LocalDumps, ProcDump, WPR,
    DISM, and SFC commands without silently changing system-level settings.
  - Support packages and state snapshots now include CrashScope universal crash
    rows, fingerprints, taxonomy, action plan, evidence-tool readiness, and
    LocalDump configuration.

v5.1 Crash Intelligence additions:
  - Crash Intel tab adds likely-cause scoring with confidence levels and
    evidence summaries.
  - Crash Heatmap groups repeated app/code/module signatures and shows frequency.
  - Change Correlation compares the newest crash anchor against recent Windows
    updates, driver dates, software installs, and GPU/System display events.
  - Crash Intelligence summaries are included in reports, support packages,
    snapshots, and no-GUI universal output.
  - Official references now include Microsoft GPU TDR, Reliability Monitor WMI,
    Application Verifier, and DebugDiag documentation. Application Verifier is
    documented only as an advanced concept; the tool does not enable it.

v5.2 Stability Workbench additions:
  - Stability tab adds a unified evidence timeline across crash events, WER
    folders, Reliability Monitor records, GPU/TDR display signals, Defender
    ASR/Controlled Folder Access events, recent updates/drivers/software, FH6
    local reports, and user-data timestamps.
  - Evidence Insights summarize each lane and blend in root-cause score signals
    so the next move is easier to choose.
  - Generated Runbook creates step-by-step actions with mode, risk, why, and
    success-check fields.
  - Stability exports write text, JSON, and CSV artifacts into
    FH6TOOLBELT\CompanionDoctorData\CrashScope_Universal.
  - Support packages, state snapshots, reports, self-test, and no-GUI universal
    output now include Stability timeline/insight/runbook artifacts.
  - Official references now include Defender ASR event logs, Controlled Folder
    Access behavior, and GFlags/PageHeap documentation. Advanced instrumentation
    is documented but not silently enabled.

v5.3 Experiment Lab additions:
  - Experiments tab adds evidence-quality scoring for crash events, fingerprints,
    WER reports, dump readiness, tool readiness, unified timeline quality,
    post-crash package freshness, and attempt journal coverage.
  - One-variable experiment plan turns current crash intelligence into controlled
    tests with action, keep-constant, success-check, evidence, and risk fields.
  - Attempt Journal logs Started, Crashed, and Stable outcomes with target,
    top fingerprint, top cause, evidence quality, and notes.
  - Experiment Lab exports write text, JSON, CSV quality, CSV plan, and CSV
    journal artifacts into FH6TOOLBELT\CompanionDoctorData\CrashExperimentLab.
  - Reports, support packages, snapshots, self-test, and no-GUI universal output
    now include Experiment Lab artifacts.
  - Official references now include Microsoft clean boot guidance, Process
    Monitor, Sysinternals Suite, and Windows Memory Diagnostic.

v5.4 Crash Matrix additions:
  - Matrix tab ranks all crashing apps in the selected time window by count,
    top code/module/class, severity, focus, and recommendation.
  - Shared Signature Clusters group code/module patterns across apps so common
    GPU, runtime, dependency, and memory-fault layers are easier to see.
  - System-Wide Signals score multi-app spread, repeated memory faults,
    GPU/device instability, Defender security blocks, recent driver/update
    correlation, dump evidence gaps, and advanced-tooling gaps.
  - Matrix exports write text, JSON, CSV app leaderboard, CSV clusters, and CSV
    signals into FH6TOOLBELT\CompanionDoctorData\CrashMatrix.
  - Reports, support packages, state snapshots, self-test, and no-GUI universal
    output now include Crash Matrix artifacts.
  - Official references now include Microsoft Kernel-Power Event ID 41 guidance
    for unexpected-restart/power-loss correlation.

v5.5 CrashOps Center additions:
  - Ops Center tab turns crash triage into an evidence operations workflow:
    readiness score, capture plan, decision board, command queue, and tool
    readiness in one view.
  - Readiness scoring checks crash evidence, fingerprint strength, evidence
    quality, dump readiness, Microsoft/Sysinternals tool coverage, Matrix
    system-wide signals, security enforcement events, support-package freshness,
    and experiment journal coverage.
  - Capture Plan recommends the right next evidence mode: baseline support
    package, fingerprint control run, per-target user-mode dump, short WPR
    trace, Process Monitor launch trace, DISM/SFC health evidence, clean boot,
    or one-variable experiment.
  - Decision Board explains whether to treat the issue as FH6-specific or
    system-wide, when to capture dumps/traces, when to isolate overlays/clean
    boot, and when the package is strong enough for escalation.
  - Command Queue generates reviewable commands for snapshot, DxDiag, WER
    LocalDumps, ProcDump crash/hang capture, WPR start/stop, Process Monitor,
    wevtutil event export, DISM, SFC, and WinDbg. The tool does not silently run
    these commands.
  - CrashOps exports write text, JSON, CSV readiness, CSV capture plan, CSV
    decisions, CSV command queue, and CSV tool inventory into
    FH6TOOLBELT\CompanionDoctorData\CrashOpsCenter.
  - Dashboard gets an Ops Center quick-action button, and reports, support
    packages, state snapshots, self-test, manifest, and no-GUI universal output
    include CrashOps artifacts.
  - Official references now include WPR command-line options, WinDbg install and
    user-mode dump analysis, Windows image repair, and Microsoft TSS-style
    diagnostic collection guidance.

Important Steam Cloud note:
  Turn off Steam Cloud for Forza Horizon 6 before deleting local saves, or Steam
  may restore the same cloud data on the next launch.

Good crash-test flow:
  1. Open the tool.
  2. Health > Run Health Scan.
  3. Saves > Back up selected saves.
  4. Saves > Deep Fresh if you want save plus cache/settings cleanup.
  5. Launch > Preflight.
  6. Launch FH6.
  7. If it crashes, Reports > Build Support Package.
  8. Ops Center > Refresh, then follow the lowest-risk capture plan before
     enabling heavier dump/WPR/ProcMon evidence.
