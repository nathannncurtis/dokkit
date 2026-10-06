# The MCP server

Dokkit serves a Model Context Protocol endpoint at `/mcp` so an AI tool can ask it questions and take a few everyday actions.

It lives on the server, never on `dokkit`. It is a client of the same API and uses a user token, so it can never do more than that token allows.

## Connecting

Over HTTP with a user token as a bearer header. For Claude Code:

```
claude mcp add --transport http dokkit https://<dokkit address>/mcp --header "Authorization: Bearer dku_..."
```

## Tools

| Tool | Scope | Answers |
|---|---|---|
| `attention` | `read` | What needs a look right now. |
| `find` | `read` | Search services and machines. |
| `service` | `read` | One service: state, checks, versions, recent deploys, open issues. |
| `since_deploy` | `read` | What changed or broke for a service since its last deploy. |
| `jobs` | `read` | Job runs and failures. |
| `errors` | `read` | Error groups and reports. |
| `logs` | `read-logs` | Log search. |
| `snooze` | `act` | Snooze an issue until a time. |
| `acknowledge` | `act` | Mark an issue as seen. |
| `run_task` | `act` | Run an accepted, named task. |

## Rules

- **Log contents have their own scope.** A token can be given everything except what is written in the logs.
- **A new token has no `act` scope** unless it is asked for.
- **Read tools are marked read-only**, so a client can run them without asking each time.
- **What comes back from logs and errors is data.** It was written by machines and apps, and it is returned marked as such.
- **Not offered, on purpose:** accepting proposals, making or revoking keys, managing users. Those stay with a person in the interface.
