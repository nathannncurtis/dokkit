"""Gives every page of the site the same top bar, breadcrumb and previous/next guide.
Run after pages.py: python gallery/brand/nav.py"""
import glob, html, os, re

here = os.path.dirname(os.path.abspath(__file__))
NAMES = "https://names.dokkit.dev/"
SOURCE = "https://github.com/nathannncurtis/dokkit"

# Each section: (label, [(file or url, title, one line, soon)]).
MENU = [
    ("Get started", [
        ("install.html", "Install", "The server, then the program on each machine", False),
        ("move.html", "Move over", "From Healthchecks, Uptime Kuma or ping URLs", False),
        ("check.html", "Check a file", "Write a dokkit.toml and see what it watches", False),
        (None, "Live demo", "The real server on a sample company", True),
    ]),
    ("Build", [
        ("agents.html", "Agents", "Let a coding agent wire your app in", False),
        ("libraries.html", "Libraries", "The same calls in eleven languages", False),
        ("mcp-tools.html", "MCP tools", "Every tool an agent can use", False),
        ("api.html", "API", "Every call, for scripts", False),
        ("cli.html", "Command line", "Every dokkit command", False),
    ]),
    ("Alerts & phone", [
        ("alerts.html", "Alerts", "Paging, push, email, chat and more", False),
        ("phone.html", "Phone app", "What needs you, from anywhere", False),
    ]),
    ("Project", [
        ("security.html", "Security", "What it can and cannot do", False),
        ("changelog.html", "Changelog", "Every release", False),
        (None, "Status", "dokkit.dev's own status", True),
        (SOURCE, "Source", "The code on GitHub", False),
    ]),
]
JOURNEY = [f for _, items in MENU for f, _, _, soon in items if f and f.endswith(".html")]
CHANNELS = ["alerts-pagerduty.html", "alerts-ntfy.html", "alerts-pushover.html", "alerts-email.html", "alerts-imessage.html",
            "alerts-sms.html", "alerts-slack.html", "alerts-discord.html", "alerts-webhook.html", "alerts-home-assistant.html"]
FOOTER_ONLY = {"privacy.html": ("Project", "Privacy"), "terms.html": ("Project", "Terms")}
MARK = '<svg><use href="#mark"/></svg>'


def place(page):
    """The section and title a page sits under, or None for Home."""
    if page in CHANNELS:
        return "Alerts & phone", None
    if page in FOOTER_ONLY:
        return FOOTER_ONLY[page]
    for label, items in MENU:
        for f, title, _, _ in items:
            if f == page:
                return label, title
    return None


def bar(page, motion=True):
    where = place(page)
    groups = []
    for i, (label, items) in enumerate(MENU):
        links = []
        for f, title, line, soon in items:
            if soon:
                links.append(f'<span class="nb-item nb-soon" aria-disabled="true"><b>{title}<em>soon</em></b><small>{line}</small></span>')
                continue
            cur = ' aria-current="page"' if f == page else ""
            links.append(f'<a class="nb-item" href="{f}"{cur}><b>{title}</b><small>{line}</small></a>')
        here_cls = " nb-here" if where and where[0] == label else ""
        groups.append(f'<div class="nb-group{here_cls}"><button type="button" class="nb-top" aria-expanded="false" aria-controls="nb-m{i}">{html.escape(label)}<i aria-hidden="true"></i></button>'
                      f'<div class="nb-menu" id="nb-m{i}">{"".join(links)}</div></div>')
    toggle = '<button type="button" class="motion" id="motion" aria-pressed="true">Motion <b>on</b></button>' if motion else ""
    return (f'<header class="nb" id="nb">\n  <a class="nb-brand" href="index.html"><span class="mk">{MARK}</span>Dokkit</a>\n'
            f'  <button type="button" class="nb-burger" aria-expanded="false" aria-controls="nb-nav" aria-label="Menu"><i></i></button>\n'
            f'  <nav class="nb-nav" id="nb-nav" aria-label="Site">{"".join(groups)}</nav>\n'
            f'  {toggle}<a class="nb-claim" href="{NAMES}">Claim a name</a>\n</header>')


def crumb(page):
    where = place(page)
    if not where:
        return None
    section, title = where
    if page in CHANNELS:
        title = None
    parts = ['<a href="index.html">Dokkit</a>', f'<span>{html.escape(section)}</span>']
    if page in CHANNELS:
        parts.append('<a href="alerts.html">Alerts</a>')
    return '<p class="crumb">' + '<span aria-hidden="true">/</span>'.join(parts) + '<span aria-hidden="true">/</span><b>'


def pager(page):
    def title_of(f):
        for _, items in MENU:
            for ff, t, line, _ in items:
                if ff == f:
                    return t, line
        name = f[len("alerts-"):-len(".html")].replace("-", " ").title().replace("Pagerduty", "PagerDuty").replace("Imessage", "iMessage").replace("Sms", "SMS").replace("Ntfy", "ntfy")
        return name, "Set up " + name
    if page in CHANNELS:
        i = CHANNELS.index(page)
        prev = CHANNELS[i - 1] if i else "alerts.html"
        nxt = CHANNELS[i + 1] if i + 1 < len(CHANNELS) else "phone.html"
        up = ("alerts.html", "All channels")
    elif page in JOURNEY:
        i = JOURNEY.index(page)
        prev = JOURNEY[i - 1] if i else "index.html"
        nxt = JOURNEY[i + 1] if i + 1 < len(JOURNEY) else None
        up = None
    else:
        return None
    pt, _ = ("Home", "") if prev == "index.html" else title_of(prev)
    out = f'<a class="pg-prev" href="{prev}"><small>Back</small><b>{html.escape(pt)}</b></a>'
    if nxt:
        nt, nl = title_of(nxt)
        out += f'<a class="pg-next" href="{nxt}"><small>Next</small><b>{html.escape(nt)}</b><span>{html.escape(nl)}</span></a>'
    else:
        out += f'<a class="pg-next" href="{NAMES}"><small>Last step</small><b>Claim a name</b><span>yours.dokkit.dev for your server</span></a>'
    extra = f'<p class="pg-up"><a href="{up[0]}">{up[1]}</a></p>' if up else ""
    return f'<nav class="pager" aria-label="Where to go next">{out}</nav>{extra}'


def apply(path):
    page = os.path.basename(path)
    s = open(path, encoding="utf-8").read()
    docs = page in ("api.html", "cli.html")
    new = bar(page, motion=not docs)
    s, n = re.subn(r'<header class="(?:bar|nb|nav)"[^>]*>.*?</header>', lambda m: new, s, count=1, flags=re.S)
    if n != 1:
        return False
    if 'href="nav.css' not in s:
        s = s.replace("</head>", '<link rel="stylesheet" href="nav.css?v=1">\n</head>', 1)
    if 'src="nav.js' not in s:
        s = s.replace("</body>", '<script src="nav.js?v=1"></script>\n</body>', 1)
    c = crumb(page)
    if c:
        s = re.sub(r'<p class="crumb">.*?<b>', lambda m: c, s, count=1, flags=re.S)
    p = pager(page)
    if p:
        s = re.sub(r'\s*<section class="next"[^>]*>.*?</section>', "", s, count=1, flags=re.S)
        s = re.sub(r'\s*<nav class="pager".*?</nav>(<p class="pg-up">.*?</p>)?', "", s, count=1, flags=re.S)
        end = "\n    </div>\n  </div>\n</main>"
        if docs:
            s = re.sub(r'\s*<nav class="pager compact".*?</nav>', "", s, count=1, flags=re.S)
            s = s.replace("</article>", f"{p}\n</article>", 1)
            top = p.replace('class="pager"', 'class="pager compact"', 1)
            s = re.sub(r'(<h1>.*?</h1>\s*<p>.*?</p>)', lambda m: m.group(1) + "\n    " + top, s, count=1, flags=re.S)
        elif end in s:
            s = s.replace(end, f"\n      {p}{end}", 1)
        else:
            s = s.replace("</main>", f"{p}\n</main>", 1)
    open(path, "w", encoding="utf-8", newline="\n").write(s)
    return True


MARK_INLINE = '<svg viewBox="0 0 100 100"><circle cx="27.5" cy="30.5" r="5.4"/><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"/></svg>'


def names_copy():
    """The same bar for names.dokkit.dev, which lives on another host."""
    b = bar("", motion=False).replace(MARK, MARK_INLINE)
    b = re.sub(r'href="(?!https?:)([^"]+)"', r'href="https://dokkit.dev/\1"', b)
    b = b.replace(f'<a class="nb-claim" href="{NAMES}">', '<a class="nb-claim" href="/" aria-current="page">')
    out = os.path.join(here, "..", "..", "names")
    open(os.path.join(out, "navbar.html"), "w", encoding="utf-8", newline="\n").write(b + "\n")
    open(os.path.join(out, "nav.css"), "w", encoding="utf-8", newline="\n").write(open(os.path.join(here, "nav.css"), encoding="utf-8").read())
    open(os.path.join(out, "nav.js"), "w", encoding="utf-8", newline="\n").write(open(os.path.join(here, "nav.js"), encoding="utf-8").read())


if __name__ == "__main__":
    names_copy()
    done = [os.path.basename(f) for f in sorted(glob.glob(os.path.join(here, "*.html"))) if apply(f)]
    print("navigation on", len(done), "pages")
