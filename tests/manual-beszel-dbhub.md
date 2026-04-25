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

## DBHub — query a database via MCP

**Outcome:** an MCP-aware client (Claude Desktop, Cursor, MCP Inspector) can connect to dbhub and run a SQL query against a real database.

```bash
harbor up dbhub --open
```

The landing page (http://localhost:34831) shows the connected source (`default · sqlite · :memory:` in demo mode) and the `execute_sql` tool. **Pass:** that page renders.

Now point a client at it. Pick whichever you have:

**Claude Desktop / Cursor / any MCP client** — add an HTTP MCP server with URL `http://localhost:34831/mcp`, then ask: *"What tables are in the database?"* Expected: the model uses `execute_sql` and returns the demo `employees` schema.

**MCP Inspector** (no client install — runs in your browser):

```bash
npx @modelcontextprotocol/inspector
```

Open the URL it prints. Set Transport = `Streamable HTTP`, URL = `http://localhost:34831/mcp`, click **Connect**, then **Tools → execute_sql** and run:

```sql
SELECT first_name, last_name, salary FROM employees LIMIT 3;
```

**Pass:** three rows of demo employees come back.

To switch to a real database, set a DSN and restart:

```bash
harbor config set dbhub.dsn "postgres://user:pw@host:5432/dbname?sslmode=disable"
harbor restart dbhub
```

The landing page now lists your database; the same MCP client query flow works against it.

```bash
harbor down dbhub
```
