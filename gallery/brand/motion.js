// Pages opt in with data-type, data-fly (left|right|up|tilt|alt) and data-fly-each; without this file they are complete and still.
(() => {
  if (document.documentElement.classList.contains("still") || !window.gsap || !window.ScrollTrigger || !window.Lenis) return;
  gsap.registerPlugin(ScrollTrigger);
  const all = (q, r = document) => [...r.querySelectorAll(q)];
  const phone = matchMedia("(max-width: 640px)").matches;

  const lenis = new Lenis({ lerp: 0.09 });
  lenis.on("scroll", ScrollTrigger.update);
  gsap.ticker.add((t) => lenis.raf(t * 1000));
  gsap.ticker.lagSmoothing(0);
  document.documentElement.style.scrollBehavior = "auto";
  document.addEventListener("click", (e) => {
    const a = e.target.closest('a[href^="#"]');
    if (!a || a.getAttribute("href").length < 2) return;
    e.preventDefault();
    lenis.scrollTo(a.getAttribute("href"), { offset: -88, duration: 1.2 });
  });
  window.dokkitScroll = lenis;

  function letters(el) {
    if (/^H\d$/.test(el.tagName)) el.setAttribute("aria-label", el.textContent.replace(/\s+/g, " ").trim());
    const out = [];
    const walk = (node) => [...node.childNodes].forEach((n) => {
      if (n.nodeType === 1) return walk(n);
      const frag = document.createDocumentFragment();
      [...n.textContent].forEach((ch) => {
        const s = document.createElement("span");
        s.className = "ch";
        s.textContent = ch;
        out.push(s);
        frag.append(s);
      });
      n.replaceWith(frag);
    });
    walk(el);
    return out;
  }
  all("[data-type]").forEach((el) => {
    const chars = letters(el);
    el.classList.add("typing");
    let shown = -1;
    ScrollTrigger.create({
      trigger: el, start: "top 92%", end: el.dataset.type === "long" ? "clamp(top 40%)" : "clamp(top 62%)", scrub: true,
      onUpdate: ({ progress }) => {
        const n = Math.round(progress * chars.length);
        if (n === shown) return;
        chars.forEach((c, i) => c.classList.toggle("on", i < n));
        chars[shown - 1]?.classList.remove("cur");
        chars[n - 1]?.classList.toggle("cur", n < chars.length);
        shown = n;
      },
    });
  });

  function fly(el, from, out, hold = 1.4) {
    const tl = gsap.timeline({ scrollTrigger: { trigger: el, start: "top 100%", end: "clamp(bottom 0%)", scrub: 0.7 } });
    tl.fromTo(el, from, { x: 0, y: 0, scale: 1, rotateX: 0, opacity: 1, duration: 1, ease: "power3.out" })
      .to(el, { duration: hold })
      .to(el, { ...out, duration: 0.8, ease: "power2.in" });
  }
  const side = phone ? 40 : 140;
  const KINDS = {
    left: [{ x: -side, opacity: 0 }, { y: -30, opacity: 0.2 }],
    right: [{ x: side, opacity: 0 }, { x: -side * 0.3, opacity: 0 }],
    up: [{ y: 70, opacity: 0 }, { y: -30, opacity: 0.15 }],
    tilt: [{ y: 140, rotateX: phone ? 0 : 16, scale: 0.9, opacity: 0.3 }, { scale: 0.95, opacity: 0.35, y: -40 }],
  };
  const alts = all("[data-fly=alt]");
  all("[data-fly]").forEach((el) => {
    const kind = el.dataset.fly;
    if (kind === "alt") {
      const k = alts.indexOf(el) % 2 ? -1 : 1;
      return fly(el, { x: k * side, opacity: 0 }, { x: -k * side * 0.4, opacity: 0 }, 1.6);
    }
    if (kind === "tilt") gsap.set(el, { transformPerspective: 1600, transformOrigin: "50% 0%" });
    const [from, out] = KINDS[kind] || KINDS.up;
    fly(el, from, out, kind === "tilt" ? 2.6 : 1.4);
  });
  all("[data-fly-each] > li").forEach((li) => {
    const i = [...li.parentElement.children].indexOf(li);
    fly(li, { x: side * 0.6 + i * 30, opacity: 0 }, { x: -side * 0.3, opacity: 0 }, 1.8);
  });

  addEventListener("load", () => ScrollTrigger.refresh());
})();
