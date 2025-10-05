# Instructions: Add Automatic Logging to All Scripts

## Context
This repository has 4 deployment scripts that currently only output to console. We need to add automatic file logging while keeping console output visible.

## Goal
Make all scripts automatically log to `logs/` directory with timestamped filenames, while still showing output in the terminal.

## Implementation Steps

### Step 1: Create logs directory and gitignore

```bash
cd /home/ubuntu/event-b/nvidia-riva-conformer-streaming-ver-7

# Create logs directory
mkdir -p logs

# Create .gitignore inside logs/ to ignore all log files
cat > logs/.gitignore << 'EOF'
# Ignore all log files
*.log
EOF
```

### Step 2: Update root .gitignore

Add `logs/` directory to the root `.gitignore` file:

```bash
# Append to .gitignore
echo "" >> .gitignore
echo "# Log files" >> .gitignore
echo "logs/" >> .gitignore
```

### Step 3: Add logging to each script

For each of these 4 scripts, add the logging line **immediately after** `set -euo pipefail`:

**Scripts to update:**
1. `scripts/010-setup-build-box.sh`
2. `scripts/100-deploy-conformer-streaming.sh`
3. `scripts/200-shutdown-gpu.sh`
4. `scripts/210-startup-restore.sh`

**Line to add:**
```bash
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
```

**Example - Before:**
```bash
#!/bin/bash
set -euo pipefail

# ============================================================================
# RIVA-210: Startup GPU and Restore
```

**Example - After:**
```bash
#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# RIVA-210: Startup GPU and Restore
```

### Step 4: Verify implementation

Run this to verify the logging line was added correctly to all scripts:

```bash
grep -n "exec.*tee.*logs" scripts/*.sh
```

**Expected output:**
```
scripts/010-setup-build-box.sh:3:exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
scripts/100-deploy-conformer-streaming.sh:3:exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
scripts/200-shutdown-gpu.sh:3:exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
scripts/210-startup-restore.sh:3:exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
```

### Step 5: Test logging

Run a quick test:

```bash
# Run the shutdown script (harmless if GPU is already stopped)
./scripts/200-shutdown-gpu.sh

# Check that log file was created
ls -lh logs/200-shutdown-gpu-*.log

# View the log
tail -20 logs/200-shutdown-gpu-*.log
```

## How It Works

**The magic line explained:**
```bash
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
```

- `exec >` - Redirect all stdout
- `>(...)` - Process substitution (creates a pipe)
- `tee -a` - Copy input to both stdout AND file (append mode)
- `"logs/..."` - Log filename with timestamp
- `$(basename $0 .sh)` - Script name without .sh extension
- `$(date +%Y%m%d-%H%M%S)` - Timestamp: 20251005-083000
- `2>&1` - Redirect stderr to stdout (catches errors too)

**Result:** Everything the script prints goes to BOTH console and log file.

## Log File Naming Convention

**Format:** `<script-name>-YYYYMMDD-HHMMSS.log`

**Examples:**
- `logs/210-startup-restore-20251005-083000.log`
- `logs/100-deploy-conformer-streaming-20251005-083515.log`
- `logs/200-shutdown-gpu-20251005-220000.log`

**Benefits:**
- Chronological sorting works naturally
- Easy to identify which script created which log
- Unique timestamp prevents overwrites

## Maintenance

**Cleaning old logs:**

Option 1 - Manual:
```bash
# Delete logs older than 30 days
find logs/ -name "*.log" -mtime +30 -delete
```

Option 2 - Create cleanup script (optional):
```bash
cat > scripts/999-cleanup-old-logs.sh << 'EOF'
#!/bin/bash
# Delete logs older than 30 days
find logs/ -name "*.log" -mtime +30 -delete
echo "✅ Cleaned up logs older than 30 days"
EOF
chmod +x scripts/999-cleanup-old-logs.sh
```

## Verification Checklist

After implementation, verify:

- [ ] `logs/` directory exists
- [ ] `logs/.gitignore` contains `*.log`
- [ ] Root `.gitignore` contains `logs/`
- [ ] All 4 scripts have the `exec ... tee ...` line added
- [ ] Line is added after `set -euo pipefail` (line 3 in most scripts)
- [ ] Test script runs and creates log file in `logs/`
- [ ] Console output still visible during script execution
- [ ] Log file contains same output as console

## Troubleshooting

**Problem:** Log file not created

**Solution:** Check that:
1. `logs/` directory exists: `mkdir -p logs`
2. Script has execute permission: `chmod +x scripts/*.sh`
3. You're running from repo root: `pwd` should show `.../nvidia-riva-conformer-streaming-ver-7`

**Problem:** No console output (only log file)

**Solution:** The `tee` command should copy to both. Check:
1. Line uses `tee` not just redirect: `tee -a "logs/..."`
2. No extra redirects later in script

**Problem:** Permission denied creating log

**Solution:**
```bash
# Make logs/ writable
chmod 755 logs/
```

## Expected File Changes Summary

**New files:**
- `logs/.gitignore` (ignore log files)

**Modified files:**
- `.gitignore` (+2 lines: add `logs/`)
- `scripts/010-setup-build-box.sh` (+1 line: add logging)
- `scripts/100-deploy-conformer-streaming.sh` (+1 line: add logging)
- `scripts/200-shutdown-gpu.sh` (+1 line: add logging)
- `scripts/210-startup-restore.sh` (+1 line: add logging)

**Total changes:** 5 files modified, 1 file created

## Git Commit Message

After implementation, commit with:

```bash
git add .gitignore logs/.gitignore scripts/*.sh
git commit -m "Add automatic logging to all deployment scripts

- All scripts now log to logs/ directory with timestamps
- Console output still visible via tee
- Log format: <script-name>-YYYYMMDD-HHMMSS.log
- Added logs/.gitignore to exclude log files from git
- Enables debugging without re-running scripts

Files changed:
- scripts/010-setup-build-box.sh
- scripts/100-deploy-conformer-streaming.sh
- scripts/200-shutdown-gpu.sh
- scripts/210-startup-restore.sh
- .gitignore (added logs/)
- logs/.gitignore (new)
"
```

## Questions?

If you encounter issues:
1. Check the "Troubleshooting" section above
2. Verify each checklist item
3. Test with a simple script first: `./scripts/200-shutdown-gpu.sh`
