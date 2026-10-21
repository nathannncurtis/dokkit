"""Renders the app icon and the tray state icons from the web favicon. Needs: pip install playwright and Edge (or drop the channel)."""
import pathlib
from playwright.sync_api import sync_playwright

here = pathlib.Path(__file__).resolve().parent
svg = (here.parents[2] / "server/priv/static/favicon.svg").read_text()
inner = svg.split(">", 1)[1].rsplit("</svg>", 1)[0]
dots = {"fine": "#1d7537", "needs": "#e0675e", "down": "#8c8581"}


def page(size, dot=None):
    d = f'<circle cx="76" cy="76" r="22" fill="{dot}" stroke="#2a1203" stroke-width="5"/>' if dot else ""
    return (f'<body style="margin:0;background:transparent"><svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="0 0 100 100" width="{size}" height="{size}">{inner}{d}</svg></body>')


with sync_playwright() as p:
    b = p.chromium.launch(channel="msedge")
    pg = b.new_page(viewport={"width": 1024, "height": 1024})
    pg.set_content(page(1024))
    pg.screenshot(path=str(here / "app.png"), omit_background=True)
    for name, colour in dots.items():
        pg = b.new_page(viewport={"width": 64, "height": 64})
        pg.set_content(page(64, colour))
        pg.screenshot(path=str(here / f"tray-{name}.png"), omit_background=True)
    b.close()
