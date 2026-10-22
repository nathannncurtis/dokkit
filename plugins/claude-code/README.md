# Dokkit for Claude Code

`/dokkit:dokkit` wires the repository you are in into Dokkit, and answers questions such as "what broke since my last deploy" from your Dokkit server.

```
/plugin install dokkit --marketplace nathannncurtis/dokkit
```

Install asks for your server's address and a token made in its Settings. Both may stay empty until you have a server; set them later with `/plugin configure dokkit@dokkit`.

- With no question, `/dokkit:dokkit` writes `dokkit.toml`, adds the library for the repository's language and runs `dokkit check`. It changes nothing else and does not commit.
- With a question, it answers from your server through its MCP, with only the tools your token allows.
- dokkit.dev's own MCP comes with it and needs no account: it checks a `dokkit.toml`, gives a starting file and lists the library calls for a language.

Privacy: https://dokkit.dev/privacy.html
