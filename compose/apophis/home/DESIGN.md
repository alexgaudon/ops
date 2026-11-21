# Homelab home

A compact, quiet, practical operations page: check service reachability,
then open the right tool. The service ledger gets the main column, with
supporting bookmarks in a separate index. No oversized title or section numbers.

Use cool blue-black and slate surfaces, near-white text, and ice-blue links
in OKLCH. Avenir Next labels contrast with monospace times and HTTP codes.
Scale: .8125, 1, 1.125 and 1.45 rem; half-rem spacing; square edges, no shadows,
and no motion. Links have visible keyboard focus; at narrow widths the service
checks and links stack. Status always has a text label.

The reachability table shows HTTPS route or direct backend checks from
Apophis, labeled separately and cached for one minute. It does not imply
comprehensive application health.

The old dashboard informs the new layout: keyboard-first service search and
links above the media widgets in the main column, with St. John's weather
and service checks in the sidebar.
The static directory remains usable without JavaScript. Weather is a live
Open-Meteo snapshot cached for ten minutes, not a dependency of the checks.

Media widgets reuse the sidebar and main-column layout: recent episodes
and release calendars on the left, playback and library totals on the right.
Playback rows show the Jellyfin username beside the playback state on the
internal homepage. Device names and addresses stay out of the widget.
Fetch media data server-side with a two-minute cache. A failed API request
shows an unavailable state rather than a zero or empty library.
Recent episodes use a compact, horizontally scrollable strip of series
posters. Plain series and episode names stay visible when art is missing.
