// The device around the live app on the phone pages: an Android phone, an iPhone, or the iPhone Duo folded, open or
// turned. The app runs in an iframe at the device's own size in points; the frame is drawn here and scaled to fit.
const DEVICES = {
  android: { sw: 412, sh: 892, bez: 9, r: [46, 46, 46, 46], punch: 1 },
  iphone: { sw: 402, sh: 874, bez: 11, r: [58, 58, 58, 58], pill: 1 },
  folded: { sw: 466, sh: 678, bez: 11, r: [12, 50, 50, 12], corner: 1, hinge: 1 },
  open: { sw: 951, sh: 669, bez: 12, r: [46, 46, 46, 46], creaseV: 1 },
  tall: { sw: 669, sh: 951, bez: 12, r: [46, 46, 46, 46], creaseH: 1 },
};
const FEATURES = ["punch", "pill", "corner", "hinge", "creaseV", "creaseH"];
const DEVICE_OF = { android: "android", iphone: "iphone", folded: "duo", open: "duo", tall: "duo" };

function deviceParams(name) {
  const d = DEVICES[name], p = { sw: d.sw, sh: d.sh, bez: d.bez, r0: d.r[0], r1: d.r[1], r2: d.r[2], r3: d.r[3], rot: 0 };
  FEATURES.forEach((f) => (p[f] = d[f] || 0));
  return p;
}
function mixParams(a, b, t) {
  const o = {};
  Object.keys(a).forEach((k) => (o[k] = a[k] + (b[k] - a[k]) * t));
  return o;
}

// Builds the frame into `host` and returns a handle. `fit()` says how much room there is: { w, h } in CSS pixels.
function makeDevice(host, { src, fit, live = true }) {
  host.innerHTML =
    '<div class="dv-scale"><div class="dv-body"><div class="dv-screen">' +
    `<iframe class="dv-app" title="A demo of the Dokkit app, on made-up data" src="${src}"${live ? "" : ' tabindex="-1" aria-hidden="true"'}></iframe>` +
    '<i class="dv-crease v" aria-hidden="true"></i><i class="dv-crease h" aria-hidden="true"></i>' +
    '<i class="screen-off" aria-hidden="true"></i>' +
    '</div><i class="dv-punch" aria-hidden="true"></i><i class="dv-pill" aria-hidden="true"></i><i class="dv-corner" aria-hidden="true"></i><i class="dv-hinge" aria-hidden="true"></i></div></div>';
  const scale = host.querySelector(".dv-scale"), body = host.querySelector(".dv-body"), screen = host.querySelector(".dv-screen"), frame = host.querySelector("iframe");
  const parts = {};
  ["punch", "pill", "corner", "hinge"].forEach((f) => (parts[f] = host.querySelector(".dv-" + f)));
  parts.creaseV = host.querySelector(".dv-crease.v");
  parts.creaseH = host.querySelector(".dv-crease.h");
  let sent = null, size = null;

  function tell(device) {
    if (device === sent) return;
    sent = device;
    const post = () => frame.contentWindow?.postMessage({ type: "dokkit-device", device }, location.origin);
    post();
    frame.addEventListener("load", post, { once: true });
  }
  function apply(p, device) {
    const W = p.sw + 2 * p.bez, H = p.sh + 2 * p.bez;
    const turned = Math.abs(Math.sin((p.rot * Math.PI) / 180));
    const bw = W + (H - W) * turned, bh = H + (W - H) * turned;
    const room = fit(), k = Math.min(room.w / bw, room.h / bh);
    host.style.width = bw * k + "px";
    host.style.height = bh * k + "px";
    scale.style.transform = `scale(${k})`;
    scale.style.width = bw + "px";
    scale.style.height = bh + "px";
    body.style.width = W + "px";
    body.style.height = H + "px";
    body.style.left = (bw - W) / 2 + "px";
    body.style.top = (bh - H) / 2 + "px";
    body.style.transform = p.rot ? `rotate(${p.rot}deg)` : "";
    body.style.borderRadius = `${p.r0}px ${p.r1}px ${p.r2}px ${p.r3}px`;
    body.style.padding = p.bez + "px";
    const inner = (r) => Math.max(4, r - p.bez + 2) + "px";
    screen.style.borderRadius = `${inner(p.r0)} ${inner(p.r1)} ${inner(p.r2)} ${inner(p.r3)}`;
    const w = Math.round(p.sw), h = Math.round(p.sh);
    if (!size || size[0] !== w || size[1] !== h) {
      frame.style.width = w + "px";
      frame.style.height = h + "px";
      size = [w, h];
    }
    FEATURES.forEach((f) => (parts[f].style.opacity = String(Math.max(0, Math.min(1, p[f])))));
    if (device) tell(device);
  }
  return { apply, screen, frame, body, host };
}
