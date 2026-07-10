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
