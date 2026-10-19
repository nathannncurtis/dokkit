"""Writes the docs an AI tool is handed: api.md, cli.md, llms.txt and llms-full.txt.
Run from anywhere: python gallery/brand/agent_docs.py. Reads openapi.json and cli.json here, and docs/."""
import json, os

here = os.path.dirname(os.path.abspath(__file__))
docs = os.path.join(here, "..", "..", "docs")
site = "https://dokkit.dev"
read = lambda *p: open(os.path.join(*p), encoding="utf-8").read()
d, cli = json.loads(read(here, "openapi.json")), json.loads(read(here, "cli.json"))


def deref(o):
    while isinstance(o, dict) and "$ref" in o:
        node = d
        for k in o["$ref"].split("/")[1:]:
            node = node[k]
        o = node
    return o or {}


def example(c):
    j = next(iter(deref(c).get("content", {}).values()), {})
    e = j.get("example", next(iter(j.get("examples", {}).values()), {}).get("value"))
    return e if e is None or isinstance(e, str) else json.dumps(e, indent=2)


api = [f"# The Dokkit API\n\n{d['info']['description']}\n\nEvery call carries a key as `Authorization: Bearer <key>`. "
       "Key prefixes: `dke_` enrolment token, `dkm_` machine key, `dka_` app key (write only), "
       "`dku_` user token with the scopes `read`, `read-logs`, `act`, `admin`.\n"]
for tag in d["tags"]:
    api.append(f"\n## {tag['name']}\n\n{tag.get('description', '')}\n")
    for path, item in d["paths"].items():
        for verb in ("get", "post", "put", "patch", "delete"):
            o = item.get(verb)
            if not o or o["tags"][0] != tag["name"]:
                continue
            api.append(f"\n### {verb.upper()} {path}\n\n{o['summary']}. {o['description']}\n")
            for p in map(deref, o.get("parameters", [])):
                api.append(f"- `{p['name']}` ({p['in']}{'' if p.get('required') else ', optional'}): {p.get('description', '')}")
            sent = example(o.get("requestBody"))
            if sent:
                api.append(f"\nSend:\n\n```\n{sent}\n```")
            for code, r in o["responses"].items():
                r = deref(r)
                got = example(r) if code[0] == "2" else None
                api.append(f"\n`{code}` {r['description']}" + (f"\n\n```json\n{got}\n```" if got else ""))
api = "\n".join(api) + "\n"

cmd = ["# The `dokkit` command line\n\nOne program on each watched machine, also used in an app's repo. "
       "`dokkit help` prints this list and `dokkit help <command>` says more about one.\n"]
for g in cli["groups"]:
    cmd.append(f"\n## {g['name']}\n")
    cmd += [f"\n### `{c['synopsis']}`\n\n{c['short']} {c['more']}\n" for c in g["commands"]]
cmd.append(f"\n## Trying it with no server\n\n```\n$ dokkit check\n{cli['check']}\n```\n")
cmd = "\n".join(cmd)

index = f"""# Dokkit

> Self-hosted monitoring that says what needs a look. A server you host, one small program on each machine, and one API behind everything.

An AI tool reaches Dokkit over MCP at `/mcp` on the server, or over the HTTP API, with a user token whose scopes decide what it may do.

## Docs

- [The API]({site}/api.md): every call, with what to send and what comes back
- [The command line]({site}/cli.md): every `dokkit` command
- [The API as OpenAPI 3.1]({site}/openapi.json)
- [Everything in one file]({site}/llms-full.txt): the API, the command line, the MCP tools and the `dokkit.toml` reference
"""
files = {"api.md": api, "cli.md": cmd, "llms.txt": index,
         "llms-full.txt": "\n\n".join([index, read(docs, "mcp.md"), read(docs, "dokkit-toml.md"), cmd, api])}
for name, text in files.items():
    open(os.path.join(here, name), "w", encoding="utf-8", newline="\n").write(text)
    print(name, len(text) // 1024, "KB")
