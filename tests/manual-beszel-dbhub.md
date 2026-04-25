# Manual integration test: `beszel` + `dbhub`

Single-page checklist to verify the two services added in v0.4.11 work end-to-end.
Run after a release-candidate build. Each step lists the command and what to look for.
Total time: ~5 minutes on a host that already has the images cached.

**Pre-flight**: clean state, no harbor stack running.

```bash
./harbor.sh down
docker ps -a --filter "name=harbor.beszel\|harbor.dbhub" --format '{{.Names}}'   # → empty
```

---

## A. dbhub (host-user privilege drop, demo mode)

```bash
./harbor.sh pull dbhub
./harbor.sh up dbhub
sleep 3
```

| # | Check | Command | Pass condition |
|---|---|---|---|
| A1 | Container healthy | `docker ps --filter name=harbor.dbhub --format '{{.Status}}'` | `Up … (healthy)` |
| A2 | HTTP serves landing | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:34831/` | `200` |
| A3 | Demo mode in logs | `docker logs harbor.dbhub 2>&1 \| grep DEMO` | line containing `Running in DEMO mode` |
| A4 | PID 1 dropped to host UID | `docker exec harbor.dbhub sh -c 'cat /proc/1/status \| grep ^Uid'` | `Uid:` first column = your `id -u` (not 0) |
| A5 | Data dir owned by host user | `ls -ld services/dbhub/data` | owner = your shell user, not `root` |
| A6 | Tear down | `./harbor.sh down dbhub` | exit 0; `docker ps --filter name=harbor.dbhub` empty |

**Optional A7 (UID-mismatch fallback — only if your host UID ≠ 1000):** repeat A4. Inside `/etc/passwd` you should see a synthesized `harbor:x:<uid>:<gid>` entry — confirms the new privilege-drop path:

```bash
docker exec harbor.dbhub awk -F: '$3==<your-uid>' /etc/passwd
```

---

## B. beszel — happy path (placeholder key, sibling cascade, host-user files)

```bash
./harbor.sh config set beszel.agent.key ''     # ensure no stale key
./harbor.sh pull beszel
./harbor.sh up beszel
sleep 4
```

| # | Check | Command | Pass condition |
|---|---|---|---|
| B1 | All three containers present | `docker ps -a --filter name=harbor.beszel --format '{{.Names}}\t{{.Status}}'` | `harbor.beszel` Up, `harbor.beszel-agent` Up, `harbor.beszel-agent-init` Exited (0) |
| B2 | Init wrote a placeholder | `docker logs harbor.beszel-agent-init 2>&1 \| tail -1` | `wrote a placeholder` or `preserving existing valid key` |
| B3 | Hub serves dashboard | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:34841/` | `200` |
| B4 | Agent listening internally | `docker logs harbor.beszel-agent 2>&1 \| grep "Starting SSH server"` | line with `addr=:45876` |
| B5 | `key.pub` host-user owned | `stat -c '%U:%G' services/beszel/agent/key.pub` | `<your-user>:<your-group>` (not `root:root`) |
| B6 | Hub data dir host-user owned | `stat -c '%U:%G' services/beszel/data` | `<your-user>:<your-group>` |
| B7 | Sibling cascade on `down` | `./harbor.sh down beszel && docker ps -a --filter name=harbor.beszel --format '{{.Names}}'` | empty (all 3 gone, no orphans) |

---

## C. beszel — bad-key failure surface and recovery

```bash
./harbor.sh config set beszel.agent.key 'bogus-truncated-key'
./harbor.sh up beszel; echo "up exit=$?"
```

| # | Check | Command | Pass condition |
|---|---|---|---|
| C1 | `up` fails fast | (output above) | `up exit=1`, includes `service "beszel-agent-init" didn't complete successfully` |
| C2 | Init logs are actionable | `docker logs harbor.beszel-agent-init 2>&1 \| tail -3` | mentions `does not parse as a valid SSH public key` and the clear-and-restart command |
| C3 | Private-key rejection (regression for v0.4.11 fix) | run the validator against a private key (snippet below) | exit `1`, same error |
| C4 | Recovery: clear + restart | `./harbor.sh config set beszel.agent.key '' && ./harbor.sh up beszel && sleep 3` | all three containers up; `docker logs harbor.beszel-agent-init` shows placeholder or preserving |

C3 snippet (run while beszel is down or in any state — it's hermetic):
```bash
TMP=$(mktemp -d); ssh-keygen -t ed25519 -N "" -f "$TMP/k" -q
docker run --rm \
  -v "$PWD/services/beszel/agent-key-init.sh:/x.sh:ro" \
  -v "$TMP/agent:/agent_data" -v "$TMP/data:/beszel_data" \
  -e HARBOR_BESZEL_AGENT_KEY="$(cat "$TMP/k")" \
  -e HARBOR_USER_ID=$(id -u) -e HARBOR_GROUP_ID=$(id -g) \
  alpine:3.20 /bin/sh /x.sh; echo "exit=$?"
rm -rf "$TMP"
```

---

## D. Cleanup

```bash
./harbor.sh down beszel dbhub
docker ps -a --filter "name=harbor.beszel\|harbor.dbhub" --format '{{.Names}}'   # → empty
```

---

## Pass criteria

All A1–A6 pass, all B1–B7 pass, all C1–C4 pass. A7 is informational (only meaningful on non-1000 UID hosts).

If any step fails, capture `docker logs` output for the relevant container plus `./harbor.sh config get beszel.agent.key` and `./harbor.sh ps`, then file a bug.
