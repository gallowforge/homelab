// Helpers shared by the README visuals.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Read a captured output file from demo/ (needs --allow-file-access-from-files).
async function demo(name) {
  const r = await fetch(`demo/${name}`);
  if (!r.ok) throw new Error(`demo/${name}: ${r.status}`);
  return (await r.text()).replace(/\n$/, "");
}

const mobile = () => window.matchMedia("(max-width: 700px)").matches;

// Draw connectors between elements into an absolutely positioned <svg> that covers
// `host`. Each link: [fromEl, toEl, fromSide, toSide, className].
function connect(host, svg, links) {
  const hb = host.getBoundingClientRect();
  svg.setAttribute("width", hb.width);
  svg.setAttribute("height", hb.height);
  svg.setAttribute("viewBox", `0 0 ${hb.width} ${hb.height}`);
  const pt = (el, side) => {
    const b = el.getBoundingClientRect();
    const x = b.left - hb.left, y = b.top - hb.top;
    switch (side) {
      case "l": return [x, y + b.height / 2];
      case "r": return [x + b.width, y + b.height / 2];
      case "t": return [x + b.width / 2, y];
      case "b": return [x + b.width / 2, y + b.height];
    }
  };
  let html = "";
  for (const [a, b, sa, sb, cls] of links) {
    const [x1, y1] = pt(a, sa), [x2, y2] = pt(b, sb);
    let d;
    if ("lr".includes(sa)) {
      const mx = (x1 + x2) / 2;
      d = `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`;
    } else {
      const my = (y1 + y2) / 2;
      d = `M${x1},${y1} C${x1},${my} ${x2},${my} ${x2},${y2}`;
    }
    html += `<path class="${cls || ""}" d="${d}"/>`;
    html += `<circle class="end ${cls || ""}" cx="${x2}" cy="${y2}" r="3"/>`;
  }
  svg.innerHTML = html;
}

// One terminal line per block, so a wrapped line hangs under its first word.
const lines = (arr) => arr.map((h) => `<span class="ln">${h}</span>`).join("");
