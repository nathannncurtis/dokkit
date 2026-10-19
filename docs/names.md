# A name on dokkit.dev

Any Dokkit server can have a name such as `yours.dokkit.dev`, with a real https certificate, even when the server is on a private network. The name points at the server's own address, private addresses included. The certificate comes from Let's Encrypt, which checks a DNS record and never needs to reach the server.

## Getting one

1. Go to https://names.dokkit.dev and sign in with GitHub.
2. Pick a name: 3 to 40 lower-case letters, digits and hyphens, starting and ending with a letter or digit. An account holds at most 3 names.
3. The page shows a claim code once. It works once, within seven days.
4. On the Dokkit server, open Settings, Certificate, and paste the code under "A name on dokkit.dev". Leave the address blank to use the machine's own address, or type the IPv4 address the name should point at. Press Claim.

The server then makes a key pair, registers the public half with the claim service using the code, points the name at its address, and gets a certificate. The private key stays on the server.

The same can be done with `POST /api/v1/certificate/name` (`code`, `address`) and then `POST /api/v1/certificate/renew`, or the `claim_dokkit_name` and `renew_certificate` MCP tools.

## Keeping it

The server sends its address once a day, and at once when the address changes. Each call it signs renews the name. Certificates renew by themselves with 30 days left, through the claim service.

On the names page each name shows one of:

| State | Meaning |
|---|---|
| waiting for the server | The claim code has not been used yet. An unused name is freed when its code runs out. |
| live | The server called within the last seven days. |
| lapsing | No call for more than seven days. After 90 days without one, the records are removed. |
| lapsed | The records are gone. The server can still bring the name back by calling. After 30 more days the name is freed. |

**New claim code** on the page replaces the server's key the next time a server registers with it: use it after reinstalling, or to move the name to another server. **Release** removes the records and frees the name at once. Every name has a **Report abuse** link.

## Running the claim service

The service is in `names/`: a Go program with no dependencies outside the standard library. It is the only thing that writes records in the dokkit.dev zone for claimed names. It keeps its state in one JSON file, rewritten on each change.

Build it with `go build` in `names/`. Settings come from the environment:

| Variable | Meaning |
|---|---|
| `AZURE_TENANT`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | A service principal with the DNS Zone Contributor role on the zone, and nothing else. Required. |
| `AZURE_SUBSCRIPTION`, `AZURE_DNS_GROUP` | Where the Azure DNS zone is. Required. |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | A GitHub OAuth app whose callback is `https://names.dokkit.dev/callback`. Required. |
| `NAMES_BASE_URL` | Default `https://names.dokkit.dev`. |
| `NAMES_ZONE` | Default `dokkit.dev`. |
| `NAMES_ADDR` | Where it listens. Default `127.0.0.1:8080`. |
| `NAMES_STATE` | The state file. Default `names.json` in the working folder. |
| `NAMES_MAX` | How many names it hands out in all. Default 1000. Each name holds up to three record sets, and an Azure DNS zone holds 10,000. |
| `NAMES_RESERVED` | More names nobody may claim, separated by spaces or commas. Anything already in the zone is refused anyway. |
| `NAMES_ABUSE_EMAIL` | Where report links go. Default `abuse@dokkit.dev`. |

Caddy in front of it:

```
names.dokkit.dev {
	reverse_proxy 127.0.0.1:8080
}
```

It trusts `X-Forwarded-For` only from the same machine, so it must listen on loopback behind Caddy. Each address gets 30 requests at once and then one every two seconds; request bodies are capped at 8 KB.

## The calls a server makes

All are `POST` with a body signed like ACME (JWS, ES256 over P-256): `protected` carries `alg`, `url` (the full address of the call) and `iat` (Unix seconds, within five minutes of the service's clock). A signature is accepted once.

| Call | Signed with | Payload | Does |
|---|---|---|---|
| `/v1/register` | `jwk`, the new public key | `{"code": ...}` | Binds the key to the name the code belongs to. Answers `{"name": ...}`. |
| `/v1/address` | `kid`, the full name | `{"a": ..., "aaaa": ...}` | Sets the A and AAAA records. An empty one removes that record. |
| `/v1/txt` | `kid` | `{"value": ...}` | Adds a DNS-01 value at `_acme-challenge.<name>`. At most two are kept. |
| `/v1/txt/clear` | `kid` | `{}` | Removes the challenge values. |

Addresses may be private but not loopback, link-local, multicast or unspecified. A challenge value is 43 base64url characters and nothing else.
