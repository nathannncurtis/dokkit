"""Writes the Alerts pages, mcp-tools.html and changelog.html from the data here and in
mcp-tools.json and changelog.json. Run from anywhere: python gallery/brand/pages.py"""
import json, os
from datetime import datetime
from html import escape as e

here = os.path.dirname(os.path.abspath(__file__))
read = lambda n: json.load(open(os.path.join(here, n), encoding="utf-8"))
V = "20"
ICON = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Crect width='100' height='100' rx='24' fill='%23ff9a4d'/%3E%3Cg fill='%232a1203'%3E%3Ccircle cx='27.5' cy='30.5' r='5.4'/%3E%3Cpath d='M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z'/%3E%3C/g%3E%3C/svg%3E"
MARK = '<circle cx="27.5" cy="30.5" r="5.4"/><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"/>'
NAV = [("install.html", "Install"), (None, "Demo"), ("agents.html", "Agents"), ("api.html", "Docs"), ("phone.html", "Phone"), ("security.html", "Security"), (None, "Status"), ("https://github.com/nathannncurtis/dokkit", "Source")]
MK = '<span class="mk"><svg><use href="#mark"/></svg></span>'


def page(file, title, desc, crumbs, h1, lede, steps, body, nxt, js=None, current=None, css=None):
    nav = "".join(f'<span class="soon" title="Not built yet">{t}</span>' if not h else
                  f'<a href="{h}"{" aria-current=\"page\"" if t == current else ""}>{t}</a>' for h, t in NAV)
    crumb = "".join(f'<a href="{h}">{t}</a><span aria-hidden="true">/</span>' for h, t in crumbs)
    rail = "".join(f'<li><a href="#{i}" data-step="{i}"><i>{n}</i>{t}</a></li>' for n, (i, t) in enumerate(steps, 1))
    links = "".join(f'<a class="nl" href="{h}"><b>{b}</b><small>{s}</small></a>' for h, b, s in nxt)
    sheet = f'<link rel="stylesheet" href="{css}?v={V}">\n' if css else ""
    script = "".join(f'<script src="{j}?v={V}"></script>\n' for j in ([js] if isinstance(js, str) else js or []))
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<meta name="theme-color" content="#1e1917">
<link rel="icon" href="{ICON}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700&family=Hanken+Grotesk:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<link rel="stylesheet" href="site.css?v={V}">
{sheet}<script>(() => {{ let m = null; try {{ m = localStorage.getItem("motion"); }} catch {{}} const on = m !== "off"; if (!on) document.documentElement.classList.add("still"); }})();</script>
</head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <symbol id="mark" viewBox="0 0 100 100">{MARK}</symbol>
</svg>

<header class="bar">
  <a class="brand" href="index.html">{MK}Dokkit</a>
  <nav aria-label="Site">
    {nav}
  </nav>
  <button type="button" class="motion" id="motion" aria-pressed="true">Motion <b>on</b></button>
  <a class="claim" href="https://names.dokkit.dev/">Claim a name</a>
</header>

<main id="top" class="page">
  <header class="phead">
    <p class="crumb"><a href="index.html">Dokkit</a><span aria-hidden="true">/</span>{crumb}<b>{e(h1)}</b></p>
    <h1 class="ptitle">{e(h1)}</h1>
    <p class="plede">{lede}</p>
  </header>

  <div class="steps-wrap">
    <nav class="rail" aria-label="On this page">
      <ol>
        {rail}
      </ol>
      <span class="rail-fill" id="railFill" aria-hidden="true"></span>
    </nav>

    <div class="steps">
{body}
      <section class="next" aria-label="Where to go next">
        <h2 data-type>Next:</h2>
        <div class="next-links">
          {links}
        </div>
      </section>
    </div>
  </div>
</main>

<footer>
  <div class="fl">
    <a class="brand" href="index.html">{MK}Dokkit</a>
    <p>Server AGPL. Program and libraries Apache 2.0. Also accepts reports from Sentry's open-source SDKs, and is not affiliated with Sentry.</p>
  </div>
</footer>
<script src="https://cdnjs.cloudflare.com/ajax/libs/gsap/3.12.5/gsap.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/gsap/3.12.5/ScrollTrigger.min.js"></script>
<script src="https://unpkg.com/lenis@1.1.13/dist/lenis.min.js"></script>
<script src="site.js?v={V}"></script>
{script}<script>railFor($$(".step"), $$(".rail a"));</script>
<script src="motion.js?v={V}"></script>
</body>
</html>
'''
    open(os.path.join(here, file), "w", encoding="utf-8", newline="\n").write(html)


def step(id, h2, inner):
    return f'''      <section class="step" id="{id}">
        <h2 data-type>{h2}</h2>
{inner}
      </section>
'''


def notif(title, body, when="now", big=False):
    return f'<div class="notif{" big" if big else ""}">{MK}<b>{e(title)}<em>{when}</em></b><span>{e(body)}</span></div>'


def fields(rows):
    return '<div class="fields" data-fly="up">' + "".join(f'<div class="field"><b>{a}</b><span>{b}</span></div>' for a, b in rows) + "</div>"


SAMPLE = ("nightly-purge did not run (db-01, DOK-12)", "It was due at 01:00 and no start was reported.")

# Every channel the server can send through, in the words of its Alerts page.
CHANNELS = [
    {"id": "pagerduty", "name": "PagerDuty", "say": "Paging, for what cannot wait until morning",
     "lede": "For what cannot wait until morning. Dokkit raises a PagerDuty incident when an issue opens and <mark class=\"ok\">resolves it when the issue closes</mark>.",
     "setup": [("PagerDuty", "In PagerDuty, add an <code>Events API v2</code> integration to the service that should page you, and copy its integration key."),
               ("PagerDuty routing key", "On Dokkit's Alerts page, under PagerDuty, paste the key and press Save."),
               ("Who is told", "Choose <code>Page</code> for <code>When something stops</code>. It is the default.")],
     "more": ["A paged issue is a <code>critical</code> incident. Push can go through PagerDuty too, as a <code>warning</code>: under Push, set <code>Push goes through</code> to PagerDuty.",
              "Page and Push through PagerDuty together make one incident, at the page's severity.",
              "Each person can have their own routing key, under People, so a rule can page one person."],
     "arrives": notif("[critical] " + SAMPLE[0], "Source db-01 · Open Dokkit", big=True)},
    {"id": "ntfy", "name": "ntfy", "say": "A quiet push to your phone, through ntfy.sh or your own ntfy",
     "lede": "A quiet notification on your phone, for what should be seen today. Works with ntfy.sh or <mark class=\"n\">an ntfy server of your own</mark>.",
     "setup": [("ntfy", "Install the ntfy app and subscribe to a topic with a name nobody would guess, or use a topic on your own server."),
               ("ntfy topic address", "On Dokkit's Alerts page, under Push, paste the topic's address, such as <code>https://ntfy.sh/your-topic</code>."),
               ("Access token, if the topic needs one", "For a protected topic, paste an ntfy access token. Dokkit sends it as a bearer token."),
               ("Push goes through", "Leave it on ntfy. It is the default."),
               ("Who is told", "Choose <code>Push</code> for <code>When something is struggling</code>. It is the default.")],
     "more": ["The notification is sent at low priority, with the issue as its title and a tap that opens Dokkit.",
              "Each person can have their own topic, under People."],
     "arrives": notif(SAMPLE[0], SAMPLE[1], big=True)},
    {"id": "pushover", "name": "Pushover", "say": "A quiet push to your phone, through Pushover",
     "lede": "The same quiet push, through Pushover instead of ntfy.",
     "setup": [("Pushover", "In Pushover, create an application for Dokkit and copy its API token, and copy your user key from the front page."),
               ("Push goes through", "On Dokkit's Alerts page, under Push, choose Pushover."),
               ("Application token", "Paste the application's API token."),
               ("User key", "Paste your user key, and press Save.")],
     "more": ["It is sent at Pushover's quiet priority, so it does not make a sound, with a link that opens Dokkit.",
              "Each person can have their own user key, under People."],
     "arrives": notif(SAMPLE[0], SAMPLE[1], big=True)},
    {"id": "email", "name": "Email", "say": "Email through your own mail server, and the morning digest",
     "lede": "Email through a mail server you already use, and <mark class=\"n\">the daily digest</mark>: one email a day with what opened without paging.",
     "setup": [("Mail server", "On Dokkit's Alerts page, under Email: the server, such as <code>smtp.example.com</code>, the port (587 unless told otherwise; 25, 465, 587 and 2525 are allowed), the user name and the password."),
               ("Sent from", "The address the mail comes from, such as <code>dokkit@example.com</code>."),
               ("Email goes to", "One address, or several with commas between them."),
               ("Daily digest", "Under Limits and night, the time the digest goes out, such as <code>07:00</code>, in the time zone you choose there.")],
     "more": ["Every email is HTML, with a plain copy for mail readers that want one.",
              "The digest holds what opened without paging, new errors, and numbers close to a limit. A day with nothing to say sends nothing.",
              "Choose <code>Daily digest</code> as a channel for anything that can wait until morning."],
     "arrives": notif(SAMPLE[0], "nightly-purge did not run. It was due at 01:00 and no start was reported. On db-01. DOK-12.", big=True)},
    {"id": "imessage", "name": "iMessage", "say": "Sent from a Mac you own, signed in to Messages",
     "lede": "iMessages go out through <mark class=\"n\">a Mac that runs the dokkit program</mark> and is signed in to Messages. No other service is involved.",
     "setup": [("The Mac", "Install the program on the Mac and enrol it, like any machine, and sign it in to Messages."),
               ("dokkit imessage on", "On that Mac, run <code>dokkit imessage on</code> so it may send. macOS asks once, on its screen."),
               ("Sent from", "On Dokkit's Alerts page, under iMessage, choose that Mac."),
               ("Goes to", "Phone numbers or email addresses, with commas between them.")],
     "more": ["<code>dokkit imessage test &lt;recipient&gt;</code> on the Mac sends one message straight from it, to check Messages itself.",
              "Each person can have their own iMessage address, under People."],
     "arrives": notif(SAMPLE[0], "Messages · from your Mac", big=True)},
    {"id": "sms", "name": "SMS", "say": "Text messages through a Twilio account",
     "lede": "Text messages through your own Twilio account, for people who want a text.",
     "setup": [("Twilio account", "On Dokkit's Alerts page, under SMS, paste the account SID and the auth token from Twilio's console."),
               ("Sent from", "A Twilio number on that account, such as <code>+15555550100</code>."),
               ("Goes to", "Phone numbers, with commas between them.")],
     "more": ["Each person can have their own number, under People."],
     "arrives": notif(SAMPLE[0], "Text message", big=True)},
    {"id": "webhook", "name": "Webhook", "say": "A JSON request to any https address, when an issue opens and closes",
     "lede": "A JSON request to an https address of yours when an issue opens, and another when it closes. Use it to reach anything Dokkit does not speak to directly.",
     "setup": [("Webhook address", "On Dokkit's Alerts page, under Webhook, an address that starts with <code>https://</code>."),
               ("Who is told", "Tick <code>Webhook</code> for the states it should hear about, alone or beside another channel.")],
     "more": ["A <a href=\"alerts-slack.html\">Slack</a> or <a href=\"alerts-discord.html\">Discord</a> webhook address gets a message in their own format instead.", "Addresses on your private network are allowed. Addresses that point at the server itself, or link-local ones, are refused unless the server runs with <code>DOKKIT_ALLOW_LOCAL_ALERTS=1</code>."],
     "body": '<p class="sub-p">The request it sends:</p><div class="prompt small" data-fly="up"><pre id="hook">{\n  "event": "opened",\n  "issue": {\n    "id": "DOK-12",\n    "title": "nightly-purge did not run",\n    "note": "It was due at 01:00 and no start was reported.",\n    "machine": "db-01",\n    "state": "down",\n    "url": "https://dokkit.example.com"\n  }\n}</pre><button type="button" class="copy" data-copy="hook">Copy</button></div><p class="note">When the issue closes, the same request comes again with <code>"event": "closed"</code>.</p>'},
    {"id": "home-assistant", "name": "Home Assistant", "say": "Through the webhook, into an automation",
     "lede": "Home Assistant takes Dokkit's webhook as an automation trigger, so an issue can flash a light or speak on a speaker.",
     "setup": [("An https address", "Dokkit sends only to https, so Home Assistant needs an https address: its own certificate, or Home Assistant Cloud."),
               ("The automation", "Add the automation below in Home Assistant, with a webhook id nobody would guess."),
               ("Webhook address", "On Dokkit's Alerts page, under Webhook, paste <code>https://your-home-assistant/api/webhook/</code> and that id.")],
     "more": ["Leave <code>local_only</code> on when Dokkit and Home Assistant share a network. Turn it off only when the request comes in through Home Assistant Cloud."],
     "body": '<div class="prompt small" data-fly="up"><pre id="ha">triggers:\n  - trigger: webhook\n    webhook_id: dokkit-change-this-id\n    allowed_methods: [POST]\n    local_only: true\nconditions:\n  - condition: template\n    value_template: "{{ trigger.json.event == \'opened\' }}"\nactions:\n  - action: notify.notify\n    data:\n      title: "{{ trigger.json.issue.title }} ({{ trigger.json.issue.machine }})"\n      message: "{{ trigger.json.issue.note or trigger.json.issue.id }}"</pre><button type="button" class="copy" data-copy="ha">Copy</button></div>'},
]
CHANNELS[6:6] = [
    {"id": "slack", "name": "Slack", "say": "A message in a channel, through the webhook",
     "lede": "A message in a Slack channel when an issue opens, and another when it closes. It goes through Dokkit's webhook, which <mark class=\"n\">speaks Slack's format</mark> when the address is Slack's.",
     "setup": [("Slack", "In Slack, create an app with Incoming Webhooks switched on, add a webhook to the channel, and copy its address. It starts <code>https://hooks.slack.com/</code>."),
               ("Webhook address", "On Dokkit's Alerts page, under Webhook, paste that address and press Save."),
               ("Who is told", "Tick <code>Webhook</code> for the states the channel should hear about.")],
     "more": ["Dokkit has one webhook address, so a Slack channel takes the place of any other webhook.",
              "The message says the issue, the machine and its number, the note when it opens, and a link to Dokkit."],
     "arrives": notif("Opened: " + SAMPLE[0], SAMPLE[1] + " Open Dokkit", big=True)},
    {"id": "discord", "name": "Discord", "say": "A message in a channel, through the webhook",
     "lede": "A message in a Discord channel when an issue opens, and another when it closes. The message <mark class=\"ok\">can never mention anyone</mark>, whatever the issue's text says.",
     "setup": [("Discord", "In the channel's settings, open Integrations, then Webhooks, make a new webhook and copy its address. It starts <code>https://discord.com/api/webhooks/</code>."),
               ("Webhook address", "On Dokkit's Alerts page, under Webhook, paste that address and press Save."),
               ("Who is told", "Tick <code>Webhook</code> for the states the channel should hear about.")],
     "more": ["Dokkit has one webhook address, so a Discord channel takes the place of any other webhook.",
              "The message says the issue, the machine and its number, the note when it opens, and a link to Dokkit."],
     "arrives": notif("Opened: " + SAMPLE[0], SAMPLE[1] + " Open Dokkit", big=True)},
]
SOON = []


def channel_pages():
    names = [c["name"] for c in CHANNELS]
    for i, c in enumerate(CHANNELS):
        setup = '        <p class="sub-p">On Dokkit\'s Alerts page, in Settings. Only the owner can change it.</p>\n        ' + fields(c["setup"])
        arrives = c.get("body") or f'        <div data-fly="up">{c["arrives"]}</div>\n        <p class="note">The sample company\'s issue, as it would arrive.</p>'
        more = '<ul class="did">' + "".join(f"<li>{m}</li>" for m in c["more"]) + "</ul>"
        test = f'''        <p class="big-fact" data-fly="up">Under {e(c["name"])}, press <mark class="ok">Send a test</mark>. It says at once whether it went, or why not.</p>
        {more}'''
        nx = CHANNELS[(i + 1) % len(CHANNELS)]
        page(f"alerts-{c['id']}.html", f"Dokkit alerts by {c['name']}", f"Setting up {c['name']} for Dokkit's alerts.",
             [("alerts.html", "Alerts")], c["name"], c["lede"],
             [("setup", "Set it up"), ("arrives", "What arrives" if not c.get("body") else "What it sends"), ("test", "Try it")],
             step("setup", "Set it up", setup) + step("arrives", "What arrives" if not c.get("body") else "What it sends", arrives) + step("test", "Try it", test),
             [("alerts.html", "Every channel", "How Dokkit decides who is told"), (f"alerts-{nx['id']}.html", nx["name"], nx["say"]), ("index.html", "Back to the start", "What Dokkit is, and the working sample")])


def alerts_page():
    rows = [
        ("DOK-12", "nightly-purge did not run", "db-01 · a job · stopped", "When something stops", "Page", "PagerDuty", notif(SAMPLE[0], SAMPLE[1], "01:04"), None),
        ("DOK-09", "upload-portal is answering slowly", "web-02 · a service · struggling", "When something is struggling", "Push", "ntfy", notif("upload-portal is answering slowly (web-02, DOK-09)", "Answers are taking 4.2 s, over its 2 s limit.", "09:40"), None),
        ("DOK-14", "report-builder is answering slowly", "app-01 · a service set not to wake you · struggling", "Night, 22:00 to 07:00", "Push", "held until 07:00", notif("report-builder is answering slowly (app-01, DOK-14)", "Held through the night, then sent.", "07:00"), "opened at 02:15"),
    ]
    head = '<div class="rt routes-head"><span>The issue</span><span>What decides</span><span>Where</span><span>What arrives</span></div>'
    body_rows = "".join(f'''<div class="rt" data-route>
            <div><b><i class="s {"bad" if n == 0 else "warn"}"></i> {e(t)}</b><small>{e(sub)} · {k}</small></div>
            <div><span class="via">{e(rule)}</span>{f'<span class="held">{held}</span>' if held else ""}</div>
            <div><span class="to">{ch}</span><small>{e(where)}</small></div>
            <div>{nt}</div>
          </div>''' for n, (k, t, sub, rule, ch, where, nt, held) in enumerate(rows))
    how = f'''        <p class="sub-p">An issue alerts once, when it opens, and what it raised is resolved when it closes. Its state picks the channel.</p>
        <div class="routes" id="routes">{head}{body_rows}</div>
        <ul class="did">
          <li>Only the production environment alerts. Issues in other environments are listed, and stay quiet.</li>
          <li>If something recovers and fails again inside 30 minutes, it is the same issue, and it stays quiet.</li>
          <li>Tick more than one channel and each sends its own alert.</li>
        </ul>'''
    chan = "".join(f'<a class="nl" href="alerts-{c["id"]}.html"><b>{c["name"]}</b><small>{c["say"]}</small></a>' for c in CHANNELS)
    chan += "".join(f'<span class="nl soon"><b>{n}</b><small>{s} · soon</small></span>' for n, s in SOON)
    channels = f'''        <p class="sub-p">Each one is set up on Dokkit's Alerts page, in Settings, and has a Send a test button. Pick one to see its fields.</p>
        <div class="next-links" data-fly="up">{chan}</div>'''
    people = f'''        <p class="sub-p">Until you name people, an alert goes to the addresses set for each channel. Name them at four levels: the default, a rule, a service and a check. The most specific level that names someone decides.</p>
        <div class="cards cards-2">
          <article class="wcard" data-fly="up"><h3><i class="s ok"></i>People</h3><p>Each person can have their own email, phone, iMessage address, ntfy topic, Pushover key and PagerDuty key. Send a test to one person from their row.</p></article>
          <article class="wcard" data-fly="up"><h3><i class="s ok"></i>Rules</h3><p>A rule picks the channel and the people for a kind of issue, a state and a machine. The first rule that fits decides. A service's own routing comes first.</p></article>
          <article class="wcard" data-fly="up"><h3><i class="s warn"></i>Night</h3><p>Choose when night starts and ends, and a time zone. A service set not to wake you holds its alerts until the night ends.</p></article>
          <article class="wcard" data-fly="up"><h3><i class="s ok"></i>Limits</h3><p>The percent of a disk, or of memory for three minutes running, that needs a look. Leave either blank to switch it off.</p></article>
        </div>'''
    itself = '''        <p class="big-fact" data-fly="up">Dokkit cannot tell anyone that it is down. Give it <mark class="n">an outside heartbeat</mark>: an https address it calls every minute, at a service that alerts when the calls stop.</p>
        <details class="card"><summary>dokkit.dev as your outside heartbeat</summary><div class="card-body"><p>On the Alerts page, under Outside heartbeat, press Use beat.dokkit.dev. There is no account to make. When your server stops calling for five minutes, dokkit.dev tells the ntfy topic or webhook already set on that page, and tells it again when the calls start. Change that topic or webhook later and the heartbeat follows. If dokkit.dev itself is down, nobody is told, as with any outside service.</p></div></details>
        <ul class="did">
          <li>When Dokkit stops taking reports or cannot reach its database, it tells you on the loudest channel that is set up, unless you choose one.</li>
          <li>Lesser trouble, such as an archive folder it cannot write to or a certificate close to running out, has its own choice.</li>
        </ul>'''
    page("alerts.html", "Where Dokkit alerts reach you", "Every channel Dokkit can alert through, how it decides who is told, and how to set each one up.",
         [], "Alerts", "Dokkit tells you when something needs you, on <mark class=\"n\">the channels you set up</mark>: paging for what cannot wait, a quiet push for today, and email for the morning.",
         [("how", "How it decides"), ("channels", "The channels"), ("people", "People and rules"), ("itself", "When Dokkit is down")],
         step("how", "How it decides", how) + step("channels", "The channels", channels) + step("people", "People and rules", people) + step("itself", "When Dokkit is down", itself),
         [("alerts-pagerduty.html", "Set up paging", "PagerDuty, for what cannot wait"), ("phone.html", "The phone app", "See what needs you, read-only"), ("install.html", "Install the server", "So there is something to be told about")],
         js="alerts.js")


SCOPES = [("read", "Read", "Read states, issues, jobs and errors", "Every token has it."),
          ("read-logs", "Read logs", "Read what is written in the logs", "Switch it on for the token."),
          ("act", "Act", "Snooze, mark as seen, watch, plan downtime", "Switch it on for the token."),
          ("admin", "Admin", "Everything you can do: keys, people, rules, checks", "A full-control token, made only after you type the server's address.")]


def tools_page():
    tools = read("mcp-tools.json")
    body = f'''        <p class="sub-p">The address is your server's address with <code>/mcp</code> on the end, and the token goes in <code>Authorization: Bearer</code>. An agent is offered only the tools its token allows.</p>
        <div class="find-tools"><input type="search" id="findTool" placeholder="Find a tool, such as snooze or logs" aria-label="Find a tool" autocomplete="off"><output id="toolCount" for="findTool">{len(tools)} tools</output></div>'''
    secs = step("find", "Find a tool", body)
    for sid, name, switch, say in SCOPES:
        mine = [t for t in tools if t["scope"] == sid]
        rows = "".join(f'''<div class="tool" id="t-{t["name"]}" data-tool="{t["name"]} {e(t["description"].lower())}"><code>{t["name"]}</code><div><p>{e(t["description"])}</p>{('<div class="args">' + "".join(f'<code class="{"req" if a in t["required"] else ""}">{a}{"" if a not in t["required"] else " *"}</code>' for a in sorted(t["args"], key=lambda a: (a not in t["required"], a))) + "</div>") if t["args"] else ""}</div></div>''' for t in mine)
        inner = f'''        <p class="scope-say"><code class="{"adm" if sid == "admin" else ""}">{sid}</code><span>{switch}. {say}</span></p>
        <div class="tlist">{rows}</div>'''
        secs += step(sid, f"{name} <span>{len(mine)}</span>", inner).replace('<section class="step"', '<section class="step scope-sec"')
    page("mcp-tools.html", "Dokkit's MCP tools", f"All {len(tools)} tools of a Dokkit server's MCP, and the token access each one needs.",
         [("agents.html", "Agents")], "MCP tools",
         f"Every tool a Dokkit server's MCP offers, all <mark class=\"n\">{len(tools)}</mark>, grouped by the token access each one needs. Arguments marked * are required.",
         [("find", "Find a tool")] + [(s, f"{n} · {sum(t['scope'] == s for t in tools)}") for s, n, _, _ in SCOPES],
         secs, [("agents.html", "Connect an agent", "The prompt, the MCP address and the token"), ("api.html", "The API", "Every call, for scripts"), ("index.html", "Back to the start", "What Dokkit is, and the working sample")],
         js="mcp-tools.js")


def changelog_page():
    rels = read("changelog.json")
    days = {}
    for r in rels:
        days.setdefault(datetime.fromisoformat(r["at"]).strftime("%Y-%m-%d"), []).append(r)
    word = lambda d: datetime.strptime(d, "%Y-%m-%d").strftime("%-d %B" if os.name != "nt" else "%#d %B")
    secs = ""
    first = True
    for d, rs in days.items():
        rows = ""
        for r in rs:
            at = datetime.fromisoformat(r["at"]).strftime("%H:%M")
            ch, rest = r["changes"][:4], r["changes"][4:]
            lis = "".join(f"<li>{e(c)}</li>" for c in ch)
            more = f'<details class="card"><summary>{len(rest)} more <small>changes</small></summary><div class="card-body"><ul>{"".join(f"<li>{e(c)}</li>" for c in rest)}</ul></div></details>' if rest else ""
            rows += f'<article class="rls{" latest" if first else ""}" id="{r["version"]}"><div><code>{r["version"]}</code><time datetime="{r["at"]}">{at} Pacific</time></div><div><ul>{lis}</ul>{more}</div></article>'
            first = False
        secs += step("d" + d, word(d), f'        <div class="cl">{rows}</div>')
    lede = f"Every release, newest first: {len(rels)} since {word(list(days)[-1])}, in the words of the change itself."
    feed = '        <p class="feedline"><a href="changelog.xml">The feed</a><span>for a reader that follows it</span><a href="https://github.com/nathannncurtis/dokkit/releases">The releases on GitHub</a><span>with the files</span></p>'
    secs = secs.replace('<div class="cl">', feed + '\n        <div class="cl">', 1)
    page("changelog.html", "Dokkit changelog", "Every Dokkit release, newest first, in plain words for someone running it.",
         [], "Changelog", lede, [("d" + d, word(d)) for d in days], secs,
         [("security.html", "Check a release yourself", "The release key and three commands"), ("install.html", "Install it", "The server, then the program on each machine"), ("index.html", "Back to the start", "What Dokkit is, and the working sample")])


def check_page():
    try_it = """        <p class="sub-p">Write or paste a <code>dokkit.toml</code>. The program's own checking code, built for the browser, reads it as you type. Nothing leaves this page.</p>
        <div class="ex-row" role="group" aria-label="Start from"><span>Start from</span><button type="button" data-ex="web" class="on">A web app</button><button type="button" data-ex="worker">A worker with jobs</button><button type="button" data-ex="win">A Windows app</button><button type="button" data-ex="bad">One with a mistake</button></div>
        <div class="play" id="play">
          <div class="ed">
            <div class="ed-top"><span>dokkit.toml</span><small id="edPos"></small></div>
            <div class="ed-body"><pre class="gut" id="gut" aria-hidden="true"></pre><div class="ed-txt"><pre class="hl" id="hl" aria-hidden="true"></pre><textarea id="src" spellcheck="false" autocomplete="off" autocapitalize="off" aria-label="dokkit.toml" wrap="off"></textarea></div></div>
          </div>
          <div class="res" aria-live="polite">
            <p class="verdict" id="verdict"><i class="s none"></i><span>Loading the checker</span></p>
            <div id="plan"></div>
            <details class="card inner sends" id="sendsCard"><summary>What <code>dokkit apply</code> sends <small>JSON</small></summary><div class="card-body"><pre id="sends"></pre></div></details>
          </div>
        </div>"""
    machine = """        <p class="big-fact" data-fly="up">The browser can read the file, but only your machine can make the checks. On the machine, <code>dokkit check</code> does both, and prints <mark class="n">exactly what would be sent</mark>. It needs no server.</p>
        <div class="cmd" data-fly="left"><code id="cCheck">dokkit check dokkit.toml</code><button type="button" class="copy" data-copy="cCheck">Copy</button></div>
        <div class="prompt small" data-fly="up"><pre>dokkit.toml: upload-portal, 3 check(s)
  ok   http           http://localhost:8080/
       would send {"at":"2026-10-19T05:52:28.4482109Z","check":"http","service":"upload-portal","state":"ok","type":"state","value":11}
  ok   tcp            port 8080
       would send {"at":"2026-10-19T05:52:28.4487947Z","check":"tcp","service":"upload-portal","state":"ok","type":"state","value":0}
  worker             reported by the app, not run here</pre></div>
        <p class="note">It exits with 1 when a check fails, so a build can stop on it.</p>"""
    refuses = """        <p class="sub-p">The same rules the server applies when the file is declared, in its words, and three more about what the program reads itself.</p>
        <ul class="did" data-fly="up">
          <li>A file without <code>schema = 1</code>, or a <code>[service]</code> without an <code>id</code>.</li>
          <li>A <code>service.id</code> with anything but lower-case letters, digits, dots, dashes and underscores.</li>
          <li>A <code>service.kind</code> that is not <code>service</code>, <code>job</code>, <code>dependency</code> or <code>app</code>.</li>
          <li>A job without an <code>id</code>, or a <code>schedule</code> that is not a cron line. <code>@reboot</code> has no time and is refused.</li>
          <li>A <code>fail_after</code> that is not a whole number from 1 to 100, and times that are not like <code>30s</code> or <code>5m</code>.</li>
          <li>A <code>key_env</code> that does not start with <code>DOKKIT_STATS_</code>, a stats address that is not http or https, and a logs path that leaves the file's folder.</li>
        </ul>"""
    page("check.html", "Check a dokkit.toml", "Write a dokkit.toml and see, as you type, what Dokkit will watch and what it would send.",
         [], "Check a file", "Write a <code>dokkit.toml</code> and see, as you type, whether Dokkit accepts it, <mark class=\"n\">what it will watch</mark>, and what would be sent.",
         [("try", "Try a file"), ("machine", "On your machine"), ("refuses", "What it refuses")],
         step("try", "Try a file", try_it) + step("machine", "On your machine", machine) + step("refuses", "What it refuses", refuses),
         [("libraries.html", "Add the library", "For the checks your app reports itself"), ("agents.html", "Let an agent write it", "One prompt, and it runs dokkit check for you"), ("install.html", "Install it", "The server, then the program on each machine")],
         js=["wasm_exec.js", "check.js"])


def move_page():
    bring = """        <p class="sub-p">Paste or drop a Healthchecks export, an Uptime Kuma backup, or a list of ping URLs. It is converted here, in the page, and each file is read by the program's own checker. Nothing is uploaded.</p>
        <div class="ex-row" role="group" aria-label="Start from"><span>Start from</span><button type="button" data-mv="hc" class="on">A Healthchecks export</button><button type="button" data-mv="kuma">An Uptime Kuma backup</button><button type="button" data-mv="urls">A list of ping URLs</button></div>
        <div class="play" id="mvPlay">
          <div class="ed mv-drop" id="mvDrop">
            <div class="ed-top"><span>Paste here</span><small id="mvKind"></small></div>
            <textarea id="mvSrc" class="mv-src" spellcheck="false" autocomplete="off" autocapitalize="off" aria-label="An export or a list of ping URLs" wrap="off"></textarea>
            <label class="mv-pick">Or choose a file<input type="file" id="mvFile" accept=".json,.txt,.csv,application/json,text/plain"></label>
          </div>
          <div class="res" aria-live="polite">
            <p class="verdict" id="mvSum"><i class="s none"></i><span>Loading the checker</span></p>
            <button type="button" class="copy mv-all" id="mvAll" hidden>Download all</button>
            <div class="mv-out" id="mvOut"></div>
          </div>
        </div>"""
    rules = """        <div class="cards cards-2 mv-rules">
          <details class="card"><summary>From Healthchecks <small>checks list</small></summary><div class="card-body">
            <p>The export is the <code>checks</code> list of the Healthchecks API (<code>GET /api/v3/checks/</code>), or the same list on its own. One file per check, its <code>slug</code> (else its name) as the service and job id.</p>
            <ul class="did">
              <li>A cron check becomes a <code>[[job]]</code> with the same <code>schedule</code>, <code>grace</code> from its grace, and <code>max_runtime</code> the same, as Healthchecks calls a started run down once its grace passes.</li>
              <li>A schedule in a time zone other than UTC is kept as written, with a comment in the file: Dokkit reads every schedule as UTC, so it must be shifted by hand.</li>
              <li>A simple check, a period since the last ping, becomes a job with one slot each period (<code>*/5 * * * *</code> for five minutes) and a grace of the period less a minute, so a ping any time in the period counts. Periods no cron line repeats evenly keep no schedule.</li>
            </ul>
            <ul class="did no"><li>A systemd OnCalendar schedule. Tags, descriptions, keyword filters and integrations.</li></ul>
          </div></details>
          <details class="card"><summary>From Uptime Kuma <small>monitorList</small></summary><div class="card-body">
            <p>The backup file from Settings, Backup (version 1.x), read from its <code>monitorList</code>. One file per monitor, its name as the service id.</p>
            <ul class="did">
              <li><code>http</code> becomes an <code>http</code> check: <code>interval</code> as <code>every</code>, <code>timeout</code>, <code>accepted_statuscodes</code> as <code>status</code>, retries plus one as <code>fail_after</code>.</li>
              <li><code>port</code> becomes a <code>tcp</code> check with its <code>host</code> and <code>port</code>.</li>
              <li><code>push</code> becomes a job, the period mapped as for a simple Healthchecks check.</li>
            </ul>
            <ul class="did no"><li>keyword, json-query, ping, dns, docker, gRPC, databases and the rest: Dokkit has no check like them. Upside-down monitors, signed-in or non-GET requests. Headers, proxies and the TLS switch are not carried.</li></ul>
          </div></details>
          <details class="card"><summary>From a list of ping URLs <small>one per line</small></summary><div class="card-body">
            <p>One <code>[[job]]</code> per line, all in one service, <code>moved-jobs</code>, so one app key pings them all. The id is the last part of the address that is a name; an address that holds only a key is named after its host.</p>
            <ul class="did no"><li>A schedule: a URL does not say when the job runs. Add a <code>schedule</code> for Dokkit to call it late.</li></ul>
          </div></details>
        </div>"""
    calls = """        <p class="big-fact" data-fly="up">Each job keeps calling the old address and <mark class="n">calls Dokkit's as well</mark>, until Dokkit has been right about it for long enough to trust. Paging stays with the old tool until then.</p>
        <div class="prompt small" data-fly="up"><pre id="mvPing">https://your.domain.com/api/v1/in/&lt;app key&gt;/job/&lt;job id&gt;/start
https://your.domain.com/api/v1/in/&lt;app key&gt;/job/&lt;job id&gt;/ok
https://your.domain.com/api/v1/in/&lt;app key&gt;/job/&lt;job id&gt;/fail</pre><button type="button" class="copy" data-copy="mvPing">Copy</button></div>
        <p class="note">GET or POST. A POST body is kept as the last lines of the job's output, up to 16 KB, and <code>?run=</code> ties a start to its finish. The key is the service's app key (<code>dka_</code>).</p>
        <p class="sub-p">Send a file of jobs with that key. A file with <code>http</code> or <code>tcp</code> checks goes on a machine with <code>dokkit</code>, which runs them, in a folder it reads or sent with the machine's key.</p>
        <div class="cmd" data-fly="left"><code id="mvApply">DOKKIT_KEY=dka_... dokkit apply nightly-backup.dokkit.toml</code><button type="button" class="copy" data-copy="mvApply">Copy</button></div>
        <p class="sub-p">On a machine with <code>dokkit</code>, wrap the job instead: it reports the start, the exit code, the time taken and the last lines of output.</p>
        <div class="cmd" data-fly="left"><code id="mvRun">dokkit run --job nightly-backup -- ./backup.sh</code><button type="button" class="copy" data-copy="mvRun">Copy</button></div>"""
    page("move.html", "Move over to Dokkit", "Turn a Healthchecks export, an Uptime Kuma backup or a list of ping URLs into dokkit.toml files, in the browser.",
         [], "Move over", "Paste what you watch with today and get <code>dokkit.toml</code> files back, <mark class=\"n\">each one read by the real checker</mark>, with what could not come over and why.",
         [("bring", "Bring it over"), ("rules", "What becomes what"), ("calls", "Then call Dokkit")],
         step("bring", "Bring it over", bring) + step("rules", "What becomes what", rules) + step("calls", "Then call Dokkit", calls),
         [("check.html", "Check a file", "Edit one and see what Dokkit will watch"), ("api.html", "The ping URLs", "In the API, with every answer"), ("install.html", "Install it", "The server, then the program on each machine")],
         js=["wasm_exec.js", "move.js"], css="move.css")


def privacy_page():
    site = """        <ul class="did">
          <li>dokkit.dev is a static site served by GitHub Pages. It sets no cookies and has no forms that send anything.</li>
          <li>It counts visits with Cloudflare Web Analytics: which page was seen, roughly where from, and how fast it loaded. That counter sets no cookies and keeps nothing that identifies you.</li>
          <li>Its pages load fonts from Google Fonts and scripts from cdnjs and unpkg, and the counter from Cloudflare, so those services see your address when a page loads, as GitHub does for the page itself.</li>
          <li>The Check a file and Move over pages work entirely in your browser. What you type or drop there is not sent anywhere.</li>
        </ul>"""
    software = """        <p class="big-fact" data-fly="up">Dokkit runs on <mark class="n">your own hardware</mark>. What it collects stays on your server, and nothing in the program, the server or the libraries reports to dokkit.dev.</p>"""
    names = """        <p class="sub-p">To give you a name such as yours.dokkit.page, names.dokkit.dev keeps:</p>
        <ul class="did">
          <li>The account you signed in with: the provider (GitHub, Google, Microsoft or ChatGPT), the stable id it gives for you, and the display name it sends. Your email address is not asked for and not kept.</li>
          <li>Each name you claim, when you claimed it, the public key your server registered, the addresses your server set for it, and when it last checked in.</li>
          <li>A sign-in cookie, only while you are signed in, to keep you signed in and to stop forged requests.</li>
        </ul>
        <p class="note">A name's records are public DNS, kept and served by Azure DNS, so anyone can look up the address it points to. Released or lapsed names are deleted, with their records. Your address is held in memory for a few minutes to limit how often one connection can make requests, and is not written down.</p>"""
    relay = """        <ul class="did">
          <li>The shared relay at relay.dokkit.dev keeps a mailbox for each server that signs up: sealed snapshots it cannot read, and the time each arrived. A mailbox with no upload for 30 days is deleted with its contents.</li>
          <li>The public MCP at mcp.dokkit.dev reads what an agent sends it, answers, and keeps nothing.</li>
          <li>Both hold your address in memory for a short while to limit requests, and do not write it down.</li>
        </ul>"""
    ask = """        <p class="sub-p">To see what names.dokkit.dev holds for you, sign in there. To have anything removed, release your names there, or write to <a href="mailto:abuse@dokkit.dev">abuse@dokkit.dev</a>. The source of every service is public, so you can check all of this.</p>
        <p class="note">Last changed 19 October 2026.</p>"""
    page("privacy.html", "Dokkit privacy", "What dokkit.dev and its small services keep, and what they do not.",
         [], "Privacy", "Dokkit is software you run yourself. These pages cover the few things dokkit.dev runs for everyone: the site, names, the shared relay and the public MCP.",
         [("software", "The software"), ("site", "This site"), ("names", "Names"), ("relay", "Relay and MCP"), ("ask", "Ask or remove")],
         step("software", "The software", software) + step("site", "This site", site) + step("names", "Names", names) + step("relay", "Relay and MCP", relay) + step("ask", "Ask or remove", ask),
         [("terms.html", "Terms", "The rules for the free services"), ("security.html", "Security", "What the program can and cannot do"), ("index.html", "Back to the start", "What Dokkit is, and the working sample")])


def terms_page():
    free = """        <ul class="did">
          <li>names.dokkit.dev, relay.dokkit.dev and mcp.dokkit.dev are free, run on a small machine, and come with no promise of uptime or support.</li>
          <li>They may change, be limited or stop. If one is going to stop, this page says so first where that is possible.</li>
          <li>The software itself is under its own licences: AGPL 3.0 for the server, Apache 2.0 for the program, the libraries and the phone apps.</li>
        </ul>"""
    names = """        <ul class="did">
          <li>A name is for pointing at a Dokkit server you run. At most 3 names per account.</li>
          <li>A name lapses when its server stops checking in for 90 days, and is then freed for anyone.</li>
          <li>Names that impersonate someone, mislead, or are used for phishing, malware or abuse are removed, without notice. Report one at <a href="mailto:abuse@dokkit.dev">abuse@dokkit.dev</a>.</li>
          <li>Some names are kept back and cannot be claimed.</li>
        </ul>"""
    use = """        <ul class="did">
          <li>Do not try to get around the limits, overload the services, or use them for anything unlawful.</li>
          <li>Accounts and mailboxes used that way are removed.</li>
        </ul>
        <p class="big-fact" data-fly="up">The services are given <mark class="n">as they are</mark>, without warranty of any kind, and nobody running them is liable for any loss from using them, as far as the law allows.</p>
        <p class="note">Last changed 19 October 2026.</p>"""
    page("terms.html", "Dokkit terms", "The rules for dokkit.dev's free services: names, the shared relay and the public MCP.",
         [], "Terms", "The rules for the free services dokkit.dev runs for everyone. The software you install has its own licences.",
         [("free", "Free services"), ("names", "Names"), ("use", "Fair use")],
         step("free", "Free services", free) + step("names", "Names", names) + step("use", "Fair use", use),
         [("privacy.html", "Privacy", "What the services keep"), ("security.html", "Security", "What the program can and cannot do"), ("index.html", "Back to the start", "What Dokkit is, and the working sample")])


channel_pages()
alerts_page()
tools_page()
changelog_page()
check_page()
move_page()
privacy_page()


def not_found():
    body = """        <p class="big-fact" data-fly="up">Nothing lives at this address. It may have moved, or the link may have a typo in it. The rest of the site is up, and <a href="index.html">the start</a> is one click away.</p>
        <div data-keep-green></div>"""
    page("404.html", "Not found · Dokkit", "Nothing lives at this address.",
         [], "This page is down", "Keep the rest green?",
         [("gone", "Keep the rest green")], step("gone", "Keep the rest green", body),
         [("index.html", "Back to the start", "What Dokkit is, and the working sample"), ("install.html", "Install", "Get it running"), ("changelog.html", "Changelog", "What changed, release by release")],
         js="keep-green.js", css="keep-green.css")
    # served at any missing path, so every relative link must resolve from the root
    f = os.path.join(os.path.dirname(os.path.abspath(__file__)), "404.html")
    s = open(f, encoding="utf-8").read()
    if '<base href="/">' not in s:
        s = s.replace('<meta charset="utf-8">', '<meta charset="utf-8">\n<base href="/">', 1)
        open(f, "w", encoding="utf-8", newline="\n").write(s)


not_found()
terms_page()
print("wrote", len(CHANNELS) + 7, "pages")

import nav
for f in sorted(os.listdir(here)):
    if f.endswith(".html"):
        nav.apply(os.path.join(here, f))
