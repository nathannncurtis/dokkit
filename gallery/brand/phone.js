railFor($$(".step"), $$(".rail a"));

// Sealed at the server, held blind at the relay, opened on the phone. Plays once, and the page waits.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  document.documentElement.classList.add("pinned");
  const env = $("#env"), caps = $$("#pcap span"), off = $("#screenOff");
  // Points on the dotted line: a card's edge facing the next card, or the middle of the phone's screen.
  const at = (node, side) => {
    const f = $("#flow").getBoundingClientRect(), r = $(node).getBoundingClientRect();
    const across = $("#nRelay").getBoundingClientRect().left > $("#nServer").getBoundingClientRect().right;
    let x = r.left + r.width / 2, y = r.top + r.height / 2;
    const gap = across ? 32 : 20;
    if (side === "out") across ? (x = r.right + gap) : (y = r.bottom + gap);
    if (side === "in") across ? (x = r.left - gap) : (y = r.top - gap);
    return { x: x - f.left - 22, y: y - f.top - 22 };
  };
  gsap.set(caps, { opacity: 0, y: 10 });
  gsap.set(off, { opacity: 1 });
  gsap.set(env, { opacity: 0 });
  gsap.set("#nRelay .blind", { opacity: 0, y: 6 });
  const tl = gsap.timeline({ paused: true });
  tl.add(() => { const p = at("#nServer", "out"); gsap.set(env, { x: p.x, y: p.y }); })
    .to(caps[0], { opacity: 1, y: 0, duration: 0.3 })
    .to("#nServer", { borderColor: "#ff9a4d", duration: 0.3 }, "<")
    .to(env, { opacity: 1, duration: 0.3 }, "<0.1")
    .to(env, { "--shut": 1, duration: 0.25 })
    .to({}, { duration: 0.35 })
    .to(caps[0], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[1], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to("#nServer", { borderColor: "", duration: 0.3 }, "<")
    .to(env, { x: () => at("#nRelay", "in").x, y: () => at("#nRelay", "in").y, duration: 0.45, ease: "power2.in" }, "<")
    .to("#nRelay", { borderColor: "#ff9a4d", duration: 0.3 })
    .to("#nRelay .blind", { opacity: 1, y: 0, duration: 0.3 }, "<")
    .to(env, { x: () => at("#nRelay", "out").x, y: () => at("#nRelay", "out").y, duration: 0.7, ease: "none" }, "<")
    .to({}, { duration: 0.2 })
    .to(caps[1], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[2], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to("#nRelay", { borderColor: "", duration: 0.3 }, "<")
    .to(env, { x: () => at("#nPhone .handset").x, y: () => at("#nPhone .handset").y, duration: 0.55, ease: "power2.inOut" }, "<")
    .to(env, { "--shut": 0, duration: 0.2 })
    .to(env, { opacity: 0, scale: 1.5, duration: 0.3 })
    .to(off, { opacity: 0, duration: 0.5 }, "<");
  tl.timeScale(tl.duration() / 3.5);
  holdFor("#how", tl, "top 12%");
}
