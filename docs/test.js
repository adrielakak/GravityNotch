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

  const sheet = "cubic-bezier(0.32, 0.72, 0, 1)";
  const unfold = "cubic-bezier(0.45, 0, 0.2, 1)";
  document.querySelectorAll(".faq details").forEach((d) => {
    const summary = d.querySelector("summary");
    const content = d.querySelector("summary ~ *");
    if (!summary) return;
    let anim = null;
    let fade = null;
    d.classList.toggle("is-open", d.open);

    summary.addEventListener("click", (e) => {
      e.preventDefault();
      const expanding = !d.classList.contains("is-open");
      anim?.cancel();
      fade?.cancel();

      if (reduce) {
        d.classList.toggle("is-open", expanding);
        if (expanding) {
          d.open = true;
          fade = content?.animate({ opacity: [0, 1] }, { duration: 240, easing: "ease", fill: "both" });
        } else {
          d.open = false;
        }
        return;
      }

      const from = d.getBoundingClientRect().height;
      d.classList.toggle("is-open", expanding);
      if (expanding) d.open = true;
      const to = expanding ? d.getBoundingClientRect().height : summary.getBoundingClientRect().height;

      anim = d.animate(
        { height: [`${from}px`, `${to}px`] },
        { duration: expanding ? 520 : 400, easing: unfold }
      );
      if (content) {
        fade = content.animate(
          expanding
            ? { opacity: [0, 1], transform: ["translateY(-12px)", "translateY(0)"], filter: ["blur(4px)", "blur(0)"] }
            : { opacity: [1, 0], transform: ["translateY(0)", "translateY(-6px)"], filter: ["blur(0)", "blur(2px)"] },
          expanding
            ? { duration: 460, delay: 140, easing: sheet, fill: "backwards" }
            : { duration: 220, easing: "ease-in", fill: "forwards" }
        );
      }
      anim.onfinish = () => {
        anim = null;
        if (!expanding) {
          d.open = false;
          fade?.cancel();
        }
      };
    });
  });
})();
