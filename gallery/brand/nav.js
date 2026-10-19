(() => {
  const nb = document.getElementById("nb");
  if (!nb) return;
  const burger = nb.querySelector(".nb-burger");
  burger.addEventListener("click", () => {
    const open = nb.classList.toggle("open");
    burger.setAttribute("aria-expanded", open);
  });
  // Touch screens have no hover, so a tap opens a section and a second tap or a tap elsewhere closes it.
  nb.addEventListener("click", (e) => {
    const top = e.target.closest(".nb-top");
    if (!top || matchMedia("(max-width: 960px)").matches) return;
    const was = top.getAttribute("aria-expanded") === "true";
    nb.querySelectorAll(".nb-top").forEach((t) => t.setAttribute("aria-expanded", "false"));
    top.setAttribute("aria-expanded", String(!was));
  });
  document.addEventListener("click", (e) => {
    if (!e.target.closest(".nb-group")) nb.querySelectorAll(".nb-top").forEach((t) => t.setAttribute("aria-expanded", "false"));
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    nb.querySelectorAll(".nb-top").forEach((t) => t.setAttribute("aria-expanded", "false"));
    nb.classList.remove("open");
    burger.setAttribute("aria-expanded", "false");
  });
})();
