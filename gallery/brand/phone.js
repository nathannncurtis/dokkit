railFor($$(".step"), $$(".rail a"));

// Sealed at the server, held blind at the relay, opened on the phone. Plays once, and the page waits.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  document.documentElement.classList.add("pinned");
  const env = $("#env"), caps = $$("#pcap span"), rows = $$("#screen p");
  const at = (node) => {
    const f = $("#flow").getBoundingClientRect(), r = $(node).getBoundingClientRect();
    return { x: r.left - f.left + r.width / 2 - 22, y: r.top - f.top + r.height / 2 - 22 };
  };
  gsap.set(caps, { opacity: 0, y: 10 });
  gsap.set(rows, { opacity: 0, y: 8 });
  gsap.set(env, { opacity: 0 });
  gsap.set("#nRelay .blind", { opacity: 0, y: 6 });
  const tl = gsap.timeline({ paused: true });
  tl.add(() => { const p = at("#nServer"); gsap.set(env, { x: p.x, y: p.y }); })
    .to(caps[0], { opacity: 1, y: 0, duration: 0.3 })
    .to("#nServer", { borderColor: "#ff9a4d", duration: 0.3 }, "<")
    .to(env, { opacity: 1, scale: 1, duration: 0.3 }, "<0.1")
    .to(env, { "--shut": 1, duration: 0.25 })
    .to({}, { duration: 0.4 })
    .to(caps[0], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[1], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to(env, { x: () => at("#nRelay").x, y: () => at("#nRelay").y, duration: 0.6, ease: "power2.inOut" }, "<")
    .to("#nServer", { borderColor: "", duration: 0.3 }, "<")
    .to("#nRelay", { borderColor: "#ff9a4d", duration: 0.3 })
    .to("#nRelay .blind", { opacity: 1, y: 0, duration: 0.3 }, "<")
    .to({}, { duration: 0.5 })
    .to(caps[1], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[2], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to(env, { x: () => at("#nPhone").x, y: () => at("#nPhone").y, duration: 0.6, ease: "power2.inOut" }, "<")
    .to("#nRelay", { borderColor: "", duration: 0.3 }, "<")
    .to(env, { "--shut": 0, duration: 0.2 })
    .to(env, { opacity: 0, scale: 1.6, duration: 0.3 })
    .to(rows, { opacity: 1, y: 0, stagger: 0.08, duration: 0.35, ease: "power3.out" }, "<");
  tl.timeScale(tl.duration() / 3.5);
  holdFor("#how", tl, "top 12%");
}
