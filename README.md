# NMS Save Version Tool

English | [日本語](README.ja.md)

This is a Windows GUI tool for **rewriting the version number recorded in No Man's Sky (PC edition) save data**.  
After playing once on a newer build, the save’s version may increase, making it unreadable by older builds (e.g., after switching to a beta build or rolling back). By reverting the version number with this tool, you can load the save again in an older build.

- No additional installation required (works with Windows 10/11’s default PowerShell 5.1 and .NET Framework)
- Japanese / English UI (auto‑switches based on Windows display language)
- Automatically backs up the entire save folder before making changes

> **Note**: This is an unofficial tool. It has no affiliation with Hello Games. Modifying save data is done at your own risk.  
> Changing the version number does not guarantee that data added in newer builds will be handled correctly by older builds.

## How to Use

1. Download via **Code → Download ZIP** from the top right, then extract it wherever you like.
2. (Optional, first time only) Double‑click `Create Desktop Shortcut.vbs` to create a desktop shortcut.
3. **After closing No Man's Sky**, double‑click the shortcut (or `NMSVersionTool.vbs`).
4. The save folder is automatically selected and the current version of each save is displayed.
5. Enter the desired number in **Target version** and check the saves you want to change, then press **Back up and change**.
6. If a Steam Cloud conflict dialog appears, choose **Local**.

Backups are created under `%USERPROFILE%\NMS_backup_<timestamp>`. To revert, copy the contents back into the save folder.

### Double‑Click Doesn’t Launch

Files extracted from ZIP may be blocked by Windows. Right‑click the original ZIP → **Properties** → check **Unblock**, then re‑extract.

If running `.vbs` files is blocked by your security settings, start the tool from the extracted folder with:

```
powershell -NoProfile -ExecutionPolicy Bypass -STA -File NMSVersionTool.ps1
```

The tool does not work where PowerShell runs in Constrained Language Mode (e.g. some managed work PCs).

## Compatibility

| Item | Status |
|---|---|
| Steam version (`%APPDATA%\HelloGames\NMS\st_<ID>`) | Tested and works |
| GOG version (DefaultUser folder) | Folder is detected but not yet verified |
| Xbox / Game Pass version | Unsupported (different save format) |
| Game modes | Verified in Normal mode. Other modes are handled, but untested |

**Limitations**

- Cannot change the number of digits (e.g., 9999 → 10000)
- Does not support meta files that differ from the verified format (not 432 bytes). In such cases it shows an error without making any changes.

## How It Works

- `save*.hg` is LZ4‑compressed JSON starting with `{"F2P":<value>,`.  
  `F2P = base version + game mode × 512`.
- `mf_save*.hg` is XXTEA‑encrypted metadata containing the base version and game mode.
- The tool rewrites only the numeric value of `F2P` (same digit count) in the uncompressed header of the compressed data, and the base version in the metadata. File size remains unchanged.
- Before writing, it verifies that all other bytes are identical after decompression, then replaces both files via temporary files. If the metadata replacement fails, it restores the original save file.
- The “Version” shown on screen is the base version (e.g., `F2P` 4738 in Normal mode corresponds to 4226).

## Files

| File | Contents |
|---|---|
| `NMSVersionTool.vbs` | Launcher (starts GUI without a console window) |
| `NMSVersionTool.ps1` | GUI script |
| `NmsSave.cs` | Processing engine (compiled by PowerShell at launch) |
| `Create Desktop Shortcut.vbs` | Creates a desktop shortcut |
| `tests/Test-NmsSave.ps1` | Tests using synthetic saves |

Run tests with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-NmsSave.ps1
```

## License

MIT License
