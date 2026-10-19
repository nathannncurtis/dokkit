# A name on dokkit.dev

Any Dokkit server can have a name such as `yours.dokkit.dev`, with a real https certificate, even when the server is on a private network. The name points at the server's own address, private addresses included. The certificate comes from Let's Encrypt, which checks a DNS record and never needs to reach the server.

## Getting one

1. Go to https://names.dokkit.dev and sign in with GitHub, Google, Microsoft or Apple, or under "More" with GitLab, Discord or Codeberg.
2. Pick a name: 3 to 40 lower-case letters, digits and hyphens, starting and ending with a letter or digit. An account holds at most 3 names. Each sign-in is its own account: names claimed after signing in with Google are not shown when signing in with GitHub.
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
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | A GitHub OAuth app. Turns on "Sign in with GitHub". |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | A Google OAuth client of type Web application. Turns on "Sign in with Google". |
| `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET` | A Microsoft Entra app registration for personal and work or school accounts, with a client secret. Turns on "Sign in with Microsoft". |
| `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `APPLE_PRIVATE_KEY_FILE` | The Apple Developer team id, the Sign in with Apple key's id, the Services ID, and the path to that key's `.p8` file. All four turn on "Sign in with Apple". See below. |
| `CHATGPT_CLIENT_ID`, `CHATGPT_CLIENT_SECRET` | An OpenAI "Sign in with ChatGPT" client. Listed under "More". |
| `GITLAB_CLIENT_ID`, `GITLAB_CLIENT_SECRET` | A gitlab.com application. Listed under "More". |
| `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET` | A Discord application's OAuth2 client. Listed under "More". |
| `CODEBERG_CLIENT_ID`, `CODEBERG_CLIENT_SECRET` | A Codeberg OAuth2 application. Listed under "More". |
| `NAMES_BASE_URL` | Default `https://names.dokkit.dev`. |
| `NAMES_ZONE` | Default `dokkit.dev`. |
| `NAMES_ADDR` | Where it listens. Default `127.0.0.1:8080`. |
| `NAMES_STATE` | The state file. Default `names.json` in the working folder. |
| `NAMES_MAX` | How many names it hands out in all. Default 1000. Each name holds up to three record sets, and an Azure DNS zone holds 10,000. |
| `NAMES_RESERVED` | More names nobody may claim, separated by spaces or commas. Anything already in the zone is refused anyway. |
| `NAMES_ABUSE_EMAIL` | Where report links go. Default `abuse@dokkit.dev`. |

### Sign-in

Each sign-in is on when both its client id and secret are set (for Apple, all four settings), and only those show on the page. GitHub, Google, Microsoft and Apple are the large buttons; the others are a small "More" row under them. At least one must be set, or the service does not start. Register these redirect URIs, built from `NAMES_BASE_URL`:

| Sign-in | Redirect URI | Where to register it | Asks for |
|---|---|---|---|
| GitHub | `https://names.dokkit.dev/callback/github` | The OAuth app's "Authorization callback URL". An app registered with `https://names.dokkit.dev/callback` also accepts it, since GitHub allows paths under the callback. | no scopes: public profile only |
| Google | `https://names.dokkit.dev/callback/google` | The client's "Authorized redirect URIs" in Google Cloud. | `openid profile` |
| Microsoft | `https://names.dokkit.dev/callback/microsoft` | The app registration's Web platform redirect URIs. Supported account types: accounts in any organizational directory and personal Microsoft accounts. | `openid profile` |
| Apple | `https://names.dokkit.dev/callback/apple` | The Services ID's "Return URLs". | no scopes: no name, no email |
| ChatGPT | `https://names.dokkit.dev/callback/chatgpt` | The OpenAI sign-in client's redirect URIs. | `openid profile` |
| GitLab | `https://names.dokkit.dev/callback/gitlab` | The application's "Redirect URI" under gitlab.com, Preferences, Applications. Tick "Confidential". | `openid` |
| Discord | `https://names.dokkit.dev/callback/discord` | The application's OAuth2 "Redirects" in the Discord Developer Portal. | `identify` |
| Codeberg | `https://names.dokkit.dev/callback/codeberg` | The application's "Redirect URIs" under Codeberg, Settings, Applications. Leave "Confidential client" on. | `openid profile` |

Every sign-in uses the authorization-code flow with a state cookie, and every one but Apple adds PKCE (S256); Apple publishes no PKCE support, so it relies on the state, the nonce and its signed client secret. Google, Microsoft, Apple, ChatGPT, GitLab and Codeberg are OpenID Connect: the service also sends a nonce, and takes the account from the ID token's `sub` after checking its RS256 signature against the provider's published keys, its issuer, audience, expiry and nonce. Microsoft's issuer is checked per tenant, `https://login.microsoftonline.com/<tid>/v2.0`. GitHub's and Discord's accounts are the `id` from their `/user` and `/users/@me` calls.

An account is the sign-in plus its id: `github:<id>`, `google:<sub>`, `microsoft:<sub>`, `apple:<sub>`, `chatgpt:<sub>`, `gitlab:<sub>`, `discord:<id>`, `codeberg:<sub>`. The service keeps that and a display name (the GitHub login, Discord's `global_name` or `username`, the ID token's `name` or GitLab's `nickname`, and "an Apple account" for Apple, which sends no name without scopes) and nothing else from the provider; it asks for no email address and stores none.

#### Setting up Sign in with Apple

In the Apple Developer account, under Certificates, Identifiers & Profiles:

1. **App ID.** Identifiers, add an App ID (for example `dev.dokkit.app`) with the "Sign in with Apple" capability. A Services ID hangs off one.
2. **Services ID.** Identifiers, add a Services ID (for example `dev.dokkit.names`). This is `APPLE_CLIENT_ID`. Turn on "Sign in with Apple", Configure: pick the App ID as primary, add `names.dokkit.dev` under Domains and Subdomains, and `https://names.dokkit.dev/callback/apple` under Return URLs. Apple accepts only https return URLs, so it cannot be tried on plain http.
3. **Key.** Keys, add a key with "Sign in with Apple", configured for the same primary App ID. Download the `.p8` (it can be downloaded once), put it on the server readable only by the service, and set `APPLE_PRIVATE_KEY_FILE` to its path. The key's 10-character id is `APPLE_KEY_ID`.
4. **Team.** The 10-character Team ID at the top right of the account page is `APPLE_TEAM_ID`.

The service makes Apple's client secret itself for each token call: an ES256 JWT signed with the `.p8` key, header `kid` = key id, claims `iss` = team id, `sub` = Services ID, `aud` = `https://appleid.apple.com`, valid one hour (Apple allows up to six months). It asks for no scopes, so Apple answers the redirect with a plain query string and no form post, and the ID token carries only the stable `sub`. State files from before this, which held GitHub ids alone, are moved to `github:<id>` when the service starts.

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
