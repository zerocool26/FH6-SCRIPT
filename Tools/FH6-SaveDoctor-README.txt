FH6 Save Doctor v2
==================

Files:
  FH6-SaveDoctor.ps1
  Run-FH6-SaveDoctor.cmd

Recommended launch:
  Double-click Run-FH6-SaveDoctor.cmd

What it does:
  - Scans Forza Horizon 6 local save/account data.
  - Scans FH6 cache/settings and local crash report folders.
  - Detects Steam install info but marks the game install as non-cleanable.
  - Backs up selected targets to Downloads\FH6_SaveDoctor_Backups.
  - Deletes or renames selected targets only after safety checks.
  - Restores backups created by this tool.
  - Exports detailed reports to Downloads\FH6_SaveDoctor_Reports.
  - Writes per-run logs to Downloads\FH6_SaveDoctor_Logs.
  - Provides monitor mode for repeated cleanup of recreated local save/cache data.

Important:
  Turn off Steam Cloud for Forza Horizon 6 before deleting local saves, or Steam may
  restore the same cloud data on the next launch.

Useful buttons:
  Scan:
    Refreshes inventory, crash context, Steam info, and diagnostics.

  Fresh Start Saves:
    Deletes local FH6 account/save containers only.

  Deep Fresh Start:
    Deletes local FH6 account/save containers plus cache/settings such as CmsCache,
    LocalStorage_Cache, fullscreen_choice, LastLaunch.timestamp, and NarratorCachedSetting.

  Start Monitor:
    Repeatedly scans every chosen interval and deletes newly recreated matching data.
    It skips while FH6 is running unless "Stop FH6 if running" is checked.

  Restore Backup:
    Restores a backup created by this tool. Existing matching folders are renamed
    with a .pre_restore suffix first.

Safety model:
  - The script refuses to modify forzahorizon6.exe or the Steam game install folder.
  - The script refuses to delete outside known FH6 AppData, Xbox GameSave, and Steam
    userdata roots.
  - Backup is enabled by default before rename/delete operations.
  - Dry Run can be enabled to preview actions.
