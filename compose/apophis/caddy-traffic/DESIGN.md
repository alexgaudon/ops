# Caddy traffic dashboard

A read-only operator dashboard for identifying busy hosts and endpoints on
Apophis. Direction: restrained, compact, legible; **traffic as ledger**.

- Palette in OKLCH: cool ink background, raised blue-gray surface, near-white
  text, muted blue-gray labels, and a single mint accent. Amber marks data gaps;
  error counts always have text labels. Defined edges, no shadows.
- Type: Georgia for the single page title, Verdana for controls and labels,
  and monospace with tabular numerals for recorded traffic. Compact 1.15 scale
  from 0.82 to 1.65 rem, with a 1.9 rem title. Spacing unit 0.5rem, square edges.
- Signature: narrow volume bars inside the host ledger, aligned with actual
  request counts rather than a separate decorative chart.
- Plain CSS, native links and tables. Visible keyboard focus, text labels,
  mobile table stacking, no animation, no external fonts or scripts.
- Audit: tables and counts lead, empty and partial data are explicit, and no
  raw log viewer or ornamental cards compete with the traffic breakdown.
