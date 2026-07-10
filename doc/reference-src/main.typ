// Sauron System Reference — main document
#set document(
  title: "Sauron System Reference",
  author: "Jáchym Holeček",
)

#set page(
  paper: "a4",
  margin: (top: 2.4cm, bottom: 2.6cm, left: 2.4cm, right: 2.4cm),
  numbering: "1",
  header: context {
    if counter(page).get().first() > 2 [
      #set text(size: 8.5pt, fill: luma(90))
      Sauron System Reference #h(1fr) Backend · Database · CGI · DNS · DHCP
      #v(-0.5em)
      #line(length: 100%, stroke: 0.4pt + luma(180))
    ]
  },
)

#set text(font: "Noto Serif", size: 10pt, lang: "en")
#set par(justify: true, leading: 0.62em)
#set heading(numbering: "1.1")

#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  v(1em)
  block[
    #set text(size: 20pt, weight: "bold")
    #if it.numbering != none [
      #text(fill: rgb("#00427a"))[Chapter #counter(heading).display("1")]
      #v(0.2em)
    ]
    #it.body
    #v(0.3em)
    #line(length: 100%, stroke: 1.2pt + rgb("#00427a"))
  ]
  v(0.8em)
}

#show heading.where(level: 2): set text(size: 14pt, fill: rgb("#00325d"))
#show heading.where(level: 3): set text(size: 11.5pt)
#show heading: set block(above: 1.4em, below: 0.8em)

#show raw.where(block: true): it => block(
  width: 100%,
  fill: luma(248),
  stroke: 0.5pt + luma(200),
  inset: 8pt,
  radius: 3pt,
  text(font: "DejaVu Sans Mono", size: 8pt, it),
)
#show raw.where(block: false): it => box(
  fill: luma(243),
  inset: (x: 2.5pt, y: 0pt),
  outset: (y: 2.5pt),
  radius: 2pt,
  text(font: "DejaVu Sans Mono", size: 8.5pt, it),
)

#set table(stroke: 0.4pt + luma(170), inset: 5pt)
#show table: set text(size: 8.7pt)
#show table.cell.where(y: 0): set text(weight: "bold")
#show table: it => block(breakable: true, it)

#let note(title, body) = block(
  width: 100%,
  fill: rgb("#eef4fb"),
  stroke: (left: 2.5pt + rgb("#00427a")),
  inset: 9pt,
  radius: 2pt,
  [#text(weight: "bold", fill: rgb("#00325d"))[#title] #h(0.4em) #body],
)

#let warn(title, body) = block(
  width: 100%,
  fill: rgb("#fdf3ec"),
  stroke: (left: 2.5pt + rgb("#b34700")),
  inset: 9pt,
  radius: 2pt,
  [#text(weight: "bold", fill: rgb("#8a3700"))[#title] #h(0.4em) #body],
)

// ---------------------------------------------------------------- title page
#page(header: none, numbering: none)[
  #v(3.2cm)
  #align(center)[
    #text(size: 30pt, weight: "bold", fill: rgb("#00325d"))[Sauron System Reference]
    #v(0.4em)
    #text(size: 14pt, fill: luma(70))[
      Backend, Database, and Legacy CGI Internals\
      with a Practical Guide to DNS and DHCP
    ]
    #v(1.2em)
    #line(length: 55%, stroke: 1pt + rgb("#00427a"))
    #v(1.2em)
    #text(size: 11pt)[
      A comprehensive reference for building the Sauron REST API,\
      written for developers, system administrators, and frontend engineers.
    ]
    #v(4cm)
    #text(size: 10pt, fill: luma(90))[
      Covers Sauron v0.9.0 (beta) · PostgreSQL · BIND 9 · ISC dhcpd\
      Generated July 2026 from the source tree at `~/Documents/sauron`
    ]
  ]
]

// ---------------------------------------------------------------- outline
#page[
  #text(size: 18pt, weight: "bold", fill: rgb("#00325d"))[Contents]
  #v(1em)
  #set text(size: 9.2pt)
  #outline(title: none, depth: 2, indent: 1.2em)
]

#counter(page).update(1)

#include "ch1-architecture.typ"
#include "ch2-database.typ"
#include "ch3-backend.typ"
#include "ch4-security.typ"
#include "ch5-cgi.typ"
#include "ch6-generator.typ"
#include "ch7-dns.typ"
#include "ch8-dhcp.typ"
#include "ch9-api.typ"
#include "appendix.typ"
