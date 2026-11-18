(() => {
  const root = document.documentElement;
  const hero = document.querySelector(".hero");
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const ease = "cubic-bezier(0.22, 1, 0.36, 1)";

  if (hero) {
    let pending = false;
    const update = () => {
      pending = false;
      root.classList.toggle("at-hero", hero.getBoundingClientRect().bottom > 0);
    };
    const schedule = () => {
      if (!pending) { pending = true; requestAnimationFrame(update); }
    };
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule, { passive: true });
    update();
  }

  document.querySelectorAll(".faq details").forEach((d) => {
    const summary = d.querySelector("summary");
    const content = d.querySelector("summary ~ *");
    if (!summary) return;
    let anim = null;
    let fade = null;
    d.classList.toggle("is-open", d.open);

    summary.addEventListener("click", (e) => {
      if (reduce) {
        requestAnimationFrame(() => d.classList.toggle("is-open", d.open));
        return;
      }
      e.preventDefault();
      const expanding = !d.classList.contains("is-open");
      const from = d.getBoundingClientRect().height;
      anim?.cancel();
      fade?.cancel();
      d.classList.toggle("is-open", expanding);
      if (expanding) d.open = true;
      const to = expanding ? d.getBoundingClientRect().height : summary.getBoundingClientRect().height;

      anim = d.animate(
        { height: [`${from}px`, `${to}px`] },
        { duration: expanding ? 460 : 340, easing: ease }
      );
      if (content) {
        fade = content.animate(
          expanding
            ? { opacity: [0, 1], transform: ["translateY(-8px)", "translateY(0)"] }
            : { opacity: [1, 0], transform: ["translateY(0)", "translateY(-4px)"] },
          { duration: expanding ? 380 : 200, delay: expanding ? 80 : 0, easing: ease, fill: "backwards" }
        );
      }
      anim.onfinish = () => {
        anim = null;
        if (!expanding) d.open = false;
      };
    });
  });
})();
