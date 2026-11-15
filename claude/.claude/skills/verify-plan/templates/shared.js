// Shared by every verify-plan page. Inlined into each built page by verify-plan.py.
// The block between the CORE markers is DOM-free: pure functions from the document to markup
// strings, loaded by scripts/page-logic.test.sh. The wiring below it touches the DOM.

// CORE:BEGIN
var VP = (function () {
  var LANES = [
    {
      id: "unit",
      label: "Unit",
      explain:
        "One piece of code on its own; everything around it is faked. Fast, but only proves that piece's logic.",
    },
    {
      id: "integration",
      label: "Integration (real dependency)",
      explain:
        "Several real pieces run together against a real local dependency. Proves the pieces actually work together.",
    },
    {
      id: "e2e",
      label: "End-to-end",
      explain:
        "An automated test drives the whole system from the outside, as a client would.",
    },
    {
      id: "walkthrough",
      label: "Your walkthrough",
      explain:
        "You run it and judge the result yourself. Covers what automation does not reach.",
    },
  ];
  var STAGES = [
    {
      id: "shaping",
      label: "Shape the strategy",
      sub: "Agent proposes, you decide",
      href: "shaping.html",
    },
    {
      id: "map",
      label: "Agreed map and walkthrough",
      sub: "Coverage grid, steps written",
      href: "map.html",
    },
    {
      id: "run",
      label: "Run the walkthrough",
      sub: "You run each step",
      href: "map.html",
    },
    {
      id: "results",
      label: "Results",
      sub: "What passed, what failed",
      href: "map.html",
    },
  ];
  var COPY_TEXT = "/verify-plan";

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }
  function list(v) {
    return Array.isArray(v) ? v : [];
  }

  // The four lanes, with the document's own labels where it gives them.
  function lanes(d) {
    var given = list(d.lanes);
    return LANES.map(function (l) {
      var g =
        given.filter(function (x) {
          return x && x.id === l.id;
        })[0] || {};
      return {
        id: l.id,
        label: g.label || l.label,
        explain: g.explain || l.explain,
      };
    });
  }
  function byId(items, id) {
    return (
      list(items).filter(function (x) {
        return x.id === id;
      })[0] || null
    );
  }
  function partLabels(d, ids) {
    return list(ids)
      .map(function (id) {
        var p = byId(d.parts, id);
        return esc(p ? p.label : id);
      })
      .join(", ");
  }
  function laneLabel(d, id) {
    return esc(
      lanes(d)
        .filter(function (l) {
          return l.id === id;
        })
        .map(function (l) {
          return l.label;
        })[0] || id,
    );
  }
  // Page head: caption, the document's title (or its task name), and the one-line summary when given.
  function header(d, caption) {
    return (
      '<div class="cap">' +
      esc(caption) +
      "</div><h1>" +
      (d.title ? esc(d.title) : "Verification: " + esc(d.task)) +
      "</h1>" +
      (d.summary ? '<p class="sub">' + esc(d.summary) + "</p>" : "")
    );
  }
  // An empty grid cell: a requirement that carries an accepted gap is marked as one, not left as bare "none".
  function noneCell(r) {
    return r && r.accepted_gap
      ? '<td class="none acc" title="' +
          esc(r.accepted_gap) +
          '">accepted gap</td>'
      : '<td class="none">none</td>';
  }
  function reqIndex(d, id) {
    var rs = list(d.requirements);
    for (var i = 0; i < rs.length; i++) if (rs[i].id === id) return i;
    return -1;
  }
  // A requirement shown anywhere but its card: id and short label, linking to the card.
  function reqLink(d, id) {
    var i = reqIndex(d, id);
    if (i < 0) return "<b>" + esc(id) + "</b>";
    return (
      '<a class="rl" href="#r' +
      i +
      '" data-i="' +
      i +
      '"><b>' +
      esc(id) +
      "</b> &middot; " +
      esc(d.requirements[i].label) +
      "</a>"
    );
  }
  // One inline group, so a flex or grid parent never splits a comma from the link before it.
  function reqLinks(d, ids) {
    var links = list(ids)
      .map(function (id) {
        return reqLink(d, id);
      })
      .join(", ");
    return links ? '<span class="rls">' + links + "</span>" : "";
  }
  function bullets(items) {
    return list(items).length
      ? "<ul>" +
          list(items)
            .map(function (x) {
              return "<li>" + esc(x) + "</li>";
            })
            .join("") +
          "</ul>"
      : '<p class="empty">Nothing.</p>';
  }

  function stageBar(stage) {
    return (
      '<nav class="stages" aria-label="Stages">' +
      STAGES.map(function (s, i) {
        var on = s.id === stage;
        return (
          '<a href="' +
          s.href +
          '"' +
          (on ? ' class="on" aria-current="step"' : "") +
          ">" +
          (i + 1) +
          " &middot; " +
          esc(s.label) +
          (on ? " (you are here)" : "") +
          "<small>" +
          esc(s.sub) +
          "</small></a>"
        );
      }).join("") +
      "</nav>"
    );
  }

  // The one place a requirement is defined: a card per requirement, then its detail panels under the row.
  function reqCards(d) {
    var cards = "",
      details = "";
    list(d.requirements).forEach(function (r, i) {
      cards +=
        '<div class="r" id="r' +
        i +
        '" data-i="' +
        i +
        '"><button type="button" class="rb" aria-expanded="false" aria-controls="rd' +
        i +
        '">' +
        '<span class="id">' +
        esc(r.id) +
        '</span><span class="lb">' +
        esc(r.label) +
        '</span><span class="sent">' +
        esc(r.sentence) +
        "</span>" +
        (r.accepted_gap
          ? '<span class="tag gap">Accepted gap</span>'
          : "") +
        '<span class="chv" aria-hidden="true">&#9656;</span></button></div>';
      details +=
        '<div class="rd" id="rd' +
        i +
        '"><h3>' +
        esc(r.id) +
        " &middot; " +
        esc(r.label) +
        (r.lasting ? ' <span class="tag">Lasting behaviour</span>' : "") +
        '</h3><div class="cols">' +
        '<div class="s"><span class="k">Why it matters</span>' +
        esc(r.why) +
        "</div>" +
        '<div class="s"><span class="k w">How it could be wrong while tests pass</span>' +
        esc(r.wrong_when) +
        "</div>" +
        (r.accepted_gap
          ? '<div class="s"><span class="k">Accepted gap</span>' +
            esc(r.accepted_gap) +
            "</div>"
          : "") +
        "</div></div>";
    });
    if (!cards) return '<p class="empty">No requirements yet.</p>';
    return (
      '<div class="strip" id="reqs">' +
      cards +
      '</div><div id="rds">' +
      details +
      "</div>"
    );
  }

  // Text to copy plus a visible copy of it, so a blocked clipboard can fall back to selecting it.
  function copyControl(label, text) {
    var t = text == null ? COPY_TEXT : text;
    return (
      '<span class="copy" aria-live="polite"><code class="hint">' +
      esc(t) +
      "</code>" +
      '<button type="button" class="cp" data-copy="' +
      esc(t) +
      '" data-label="' +
      esc(label) +
      '">' +
      esc(label) +
      "</button></span>"
    );
  }

  return {
    LANES: LANES,
    STAGES: STAGES,
    COPY_TEXT: COPY_TEXT,
    esc: esc,
    list: list,
    lanes: lanes,
    byId: byId,
    partLabels: partLabels,
    laneLabel: laneLabel,
    header: header,
    noneCell: noneCell,
    reqIndex: reqIndex,
    reqLink: reqLink,
    reqLinks: reqLinks,
    bullets: bullets,
    stageBar: stageBar,
    reqCards: reqCards,
    copyControl: copyControl,
  };
})();
// CORE:END

// DOM wiring shared by the pages: expanders, requirement links, copy controls.
function vpFlash(el) {
  el.classList.add("flash");
  setTimeout(function () {
    el.classList.remove("flash");
  }, 1400);
}
function vpSetCard(i, open) {
  var c = document.getElementById("r" + i),
    d = document.getElementById("rd" + i);
  if (!c || !d) return;
  c.classList.toggle("open", open);
  c.querySelector(".rb").setAttribute("aria-expanded", String(open));
  d.classList.toggle("open", open);
}
function vpCopy(btn) {
  var text = btn.getAttribute("data-copy"),
    label = btn.getAttribute("data-label");
  var reset = function () {
    setTimeout(function () {
      btn.textContent = label;
    }, 1800);
  };
  var select = function () {
    var hint = btn.parentNode.querySelector(".hint");
    if (hint && window.getSelection) {
      var r = document.createRange();
      r.selectNodeContents(hint);
      var s = window.getSelection();
      s.removeAllRanges();
      s.addRange(r);
    }
    btn.textContent = "Selected, press copy keys";
    reset();
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(function () {
      btn.textContent = "Copied";
      reset();
    }, select);
  } else {
    select();
  }
}
function vpWire() {
  document.addEventListener("click", function (e) {
    var t = e.target;
    var cp = t.closest("button.cp");
    if (cp) {
      vpCopy(cp);
      return;
    }
    var a = t.closest("a.rl");
    if (a) {
      e.preventDefault();
      var i = Number(a.getAttribute("data-i"));
      vpSetCard(i, true);
      var c = document.getElementById("r" + i);
      c.scrollIntoView({ block: "center" });
      vpFlash(c);
      var b = c.querySelector(".rb");
      if (b) b.focus({ preventScroll: true });
      return;
    }
    var card = t.closest(".r");
    if (card)
      vpSetCard(
        Number(card.getAttribute("data-i")),
        !card.classList.contains("open"),
      );
  });
}
