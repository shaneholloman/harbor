# Manual smoke test: `beszel` + `dbhub`

Verify the two services added in v0.4.11 deliver their end-user outcome.
Walk through both in ~5 minutes.

---

## Beszel — monitor this host

**Outcome:** the hub dashboard shows live CPU, memory, disk, and container metrics for the machine running Harbor.

```bash
harbor up beszel --open
```

In the browser:

1. Create the admin account (any email/password — local only).
2. Click **Add System**.
   - Name: `harbor-host`
   - Host/IP: `beszel-agent`
   - Port: `45876`
   - Copy the `ssh-ed25519 AAAA…` key shown in the dialog.

Back in the terminal, paste the key and restart:

```bash
harbor config set beszel.agent.key 'ssh-ed25519 AAAA… <the key>'
harbor restart beszel
```

Wait ~30 seconds and refresh the dashboard. **Pass:** `harbor-host` row turns green with live values for CPU %, Memory, Disk, and a container count > 0. Click into the row — graphs populate within a minute.

```bash
harbor down beszel
```

---

## DBHub — query a database from Open WebUI

**Outcome:** Open WebUI talks to a SQL database through DBHub's MCP tools — no manual configuration.

```bash
harbor up webui dbhub --open
```

In Open WebUI, sign in (or create an admin), pick a tool-calling model, and ask:

> *"List 3 employees from the database with their salaries."*

**Pass:** the model invokes the `execute_sql` tool and returns three rows from the demo `employees` table.

To point at a real database, set a DSN and restart:

```bash
harbor config set dbhub.dsn "postgres://user:pw@host:5432/dbname?sslmode=disable"
harbor restart dbhub
```

The same chat now answers questions about your data.

```bash
harbor down dbhub webui
```
