# Problem 2: Diagnose Me Doctor

## Assumptions

- **The alert may be wrong.** I do not trust the monitoring report blindly. Step 1 checks it on the server first. It is probably true, but it costs one minute to confirm.
- The server has one 64GB disk, and `/` holds everything.
- NGINX is installed with `apt` (not Docker). Logs are in `/var/log/nginx`. Temp files are in `/var/lib/nginx`.
- The server is live and I have `sudo` access (by SSH or SSM).
- There may be no second server, so I avoid restarting NGINX.
- The task says "two production issues" but only describes one. I solve this one: the disk is almost full.

## Why this is serious

When the disk is full, NGINX cannot write logs or temporary files. Users start to get errors (5xx). So we must fix it fast, but carefully.

## Step 1: Check the alert is real

Log in to the server and look at the disk ourselves:

```bash
df -h          # all disks, not only /
lsblk          # disk and partition sizes
```

- **Disk is really about 99% full:** the alert is correct. Go to Step 2.
- **Disk is much lower (for example 40%):** the monitoring is wrong. Common reasons: it watches the wrong server or disk, the data is old, or it counts the wrong thing. Fix the monitor, not the server.

## Step 2: Find what uses the space

If the disk is almost 100% full, first free a few hundred MB with the quick fixes in case 4 (journal) and case 5 (apt). This keeps NGINX working. Then look for the real cause:

```bash
df -h /                                                  # how full is the disk?
df -i /                                                  # how many file slots (inodes) are used?
sudo du -xh / --max-depth=1 2>/dev/null | sort -h | tail # which folder is big?
sudo du -xh /var --max-depth=2 2>/dev/null | sort -h | tail
sudo find / -xdev -type f -size +200M 2>/dev/null        # find very big files
sudo lsof +L1 | grep nginx                               # deleted files still held open
```

Most of the time the answer is in `/var/log`.

## Step 3: Common causes, impact and fix

### 1. NGINX logs are too big (most common)

- **Why:** `logrotate` is broken or turned off, or there is a lot of traffic or many errors.
- **Check:** `ls -lh /var/log/nginx/` shows files of many GB. `systemctl status logrotate.timer` shows a problem.
- **Impact:** The disk fills up. NGINX cannot write logs. Users get errors.
- **Before we empty a log:** `truncate -s 0` removes everything inside the file, and we cannot get it back. The file stays, but it is now 0 bytes, and NGINX keeps writing to it as normal.
  So we always back up first, because logs can show the cause later (for example a traffic spike or an attack). The disk is full, so we cannot copy the files to the same disk. We send a compressed copy straight to S3, which needs no space on the server.
- **Fix now:**
  ```bash
  # 1. Back up both logs to S3
  sudo gzip -c /var/log/nginx/access.log | aws s3 cp - s3://<log-bucket>/nginx/$(hostname)-access-$(date +%F-%H%M).log.gz
  sudo gzip -c /var/log/nginx/error.log  | aws s3 cp - s3://<log-bucket>/nginx/$(hostname)-error-$(date +%F-%H%M).log.gz
  # 2. Empty the files
  sudo truncate -s 0 /var/log/nginx/access.log
  sudo truncate -s 0 /var/log/nginx/error.log
  # 3. Tell NGINX to reopen the logs
  sudo nginx -s reopen
  ```
  - Do not delete the log with `rm`. NGINX keeps it open, so the space does not come back (see case 2).
  - Do not restart NGINX. `reopen` is enough and has no downtime.
- **Fix for good:** Fix the logrotate config in `/etc/logrotate.d/nginx`: rotate daily, keep 14 files, compress. Send logs to a log service and keep only a few days on the server.

### 2. A log was deleted, but the space did not come back

- **Why:** Someone ran `rm` on a log while NGINX was still writing to it. The file is gone from the folder, but the space is still used.
- **Check:** `df` says the disk is full, but `du` shows much less. `sudo lsof +L1 | grep nginx` lists files marked "(deleted)".
- **Impact:** Same as above, and it is confusing because we cannot see the file.
- **Fix:** `sudo nginx -s reopen`. NGINX closes the old file and the space comes back. No restart is needed.
- **Prevent:** Always use `truncate`, never `rm`, on a live log.

### 3. NGINX temporary or cache files

- **Why:** NGINX saves big uploads or big responses in temp folders. If we use a cache with no size limit, it keeps growing.
- **Check:** `sudo du -sh /var/lib/nginx /var/cache/nginx`
- **Impact:** The disk fills up when traffic is high. Users get errors.
- **Fix now:** Delete old cache files: `sudo find /var/cache/nginx -type f -mmin +60 -delete`
- **Fix for good:** Set a size limit in the config, for example `proxy_cache_path ... max_size=5g inactive=60m;`. After we change the config, run `sudo nginx -t`, then `sudo nginx -s reload` (not restart).

### 4. System logs (journal and syslog)

- **Why:** `systemd` logs have no size limit, or one service writes too many messages.
- **Check:** `journalctl --disk-usage` and `ls -lhS /var/log | head`
- **Impact:** The free space slowly goes away.
- **Fix now:** `sudo journalctl --vacuum-size=200M`
- **Fix for good:** Set `SystemMaxUse=500M` in `/etc/systemd/journald.conf`, then `sudo systemctl restart systemd-journald`.

### 5. Old packages and old kernels

- **Why:** `apt` keeps downloaded packages. Old kernels stay after updates.
- **Check:** `du -sh /var/cache/apt /boot`
- **Impact:** A few GB used for nothing.
- **Fix:** `sudo apt-get clean && sudo apt-get autoremove --purge -y`

### 6. Forgotten files

- **Why:** Old backups, downloads, or test files in `/tmp`, `/var/tmp`, `/root`, or `/home`.
- **Check:** The big-file search in Step 2.
- **Impact:** Less free space.
- **Fix:**
  1. Check each file: what it is, who owns it, and when it was last changed (`ls -lh <file>` shows the size, owner, and date).
  2. Ask the team or the machine owner to confirm that we can remove it. We do not delete a file we are not sure about.
  3. After they confirm, delete it or move it to S3 (cloud storage). Do not keep backups on this server.

### 7. No inodes left (the disk shows free space, but writes fail)

- **Why:** An inode is a small record the disk keeps for each file (size, owner, where the data is). Every file uses one inode, and a disk has a fixed number of them. Millions of tiny files can use all the slots even when there is still free space. NGINX cache folders are a common cause.
- **Check:** `df -i /` shows `IUse%` at 100%. Find the folder with the most files (this can take a while):
  ```bash
  sudo find / -xdev -printf '%h\n' | sort | uniq -c | sort -nr | head
  ```
- **Impact:** We get "No space left on device" errors, but `df -h` shows free space. NGINX cannot create new log, temp, or cache files.
- **Fix now:**
  1. Check the files in the folder we found: how many there are, what they are, and who owns them.
     ```bash
     sudo find <folder> -type f | wc -l       # how many files
     sudo ls -lt <folder> | head              # newest files, with owner and date
     ```
  2. Ask the team or the machine owner to confirm that we can remove them. We do not delete files we are not sure about.
  3. After they confirm, delete the old small files:
     ```bash
     sudo find <folder> -type f -mmin +60 -delete
     ```
- **Fix for good:** Set a size limit on the NGINX cache. Delete old files on a schedule. Find the program that creates so many files and fix it.

### 8. The server was hacked

- **Why:** An attacker can fill the disk with a crypto miner, stolen data waiting to be copied out, or tools. It can also be huge logs from an attack.
- **Signs:** New big files that nobody knows about, unknown programs using CPU, unknown logins, unknown scheduled jobs, unknown open ports.
  ```bash
  sudo find / -xdev -type f -mtime -2 -size +50M 2>/dev/null  # big files from the last 2 days
  ps aux --sort=-%cpu | head                                  # unknown busy programs
  last -n 20                                                  # recent logins
  sudo grep "Accepted" /var/log/auth.log | tail               # successful SSH logins
  sudo ss -tulpn                                              # open ports and their programs
  sudo crontab -l; ls /etc/cron.*                             # unknown scheduled jobs
  ```
  Also look at `/tmp`, `/var/tmp`, `/dev/shm` and folders that start with a dot.
- **Impact:** Worse than a full disk. Data can be stolen, and the server can be used to attack others.
- **What to do:**
  1. **Do not delete or empty anything.** That destroys the evidence.
  2. Take a snapshot of the disk (for example an EBS snapshot) so we can study it later.
  3. Isolate the server, so the attacker cannot use it:
     - Stop sending users to it. This server is the NGINX load balancer, so we point the traffic to a clean server first (for example change the DNS record, or the cloud load balancer in front of it). See step 5 for the clean server.
     - If there is no other server, tell the team before we continue. Isolating means a short outage, but that is safer than keeping a hacked server online.
     - Change its security group to block all traffic in and out, except access for the security team. The attacker cannot reach the server, and the server cannot send data out.
  4. Tell the security team.
  5. Build a new clean server from a trusted image. Change all passwords, SSH keys, and TLS certificates.

## Summary

| Cause | How likely | Fix |
|---|---|---|
| 1. Big NGINX logs | High | Truncate, reopen, fix logrotate |
| 2. Deleted log still open | High | `nginx -s reopen` |
| 3. NGINX temp or cache | Medium | Clean up, set size limit |
| 4. System logs | Medium | `journalctl --vacuum-size` |
| 5. Old packages and kernels | Medium | `apt clean`, `autoremove` |
| 6. Forgotten files | Medium | Delete or move |
| 7. No inodes left | Low | Delete small files, set cache limit |
| 8. Hacked server | Low, but check | Do not delete, snapshot, isolate, rebuild |

## After the fix

- Check: `df -h /` is under 70%.
- Run `sudo logrotate -f /etc/logrotate.d/nginx` to prove log rotation works.
- Write down what we changed (what we deleted or emptied, and when).

## How to stop it from happening again

- Alerts: warn at 70% full, urgent at 85%.
- Keep logrotate and journald limits in code (for example Terraform) so every server has them.
- Send logs to a central place and keep only a few days on the server.
- Put `/var/log` on its own disk, so logs cannot fill the main disk.
- Write a short runbook.

