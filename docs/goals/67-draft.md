# Goal 67 (draft): the UI ingredients for a Finxplorer-class app

After goal 66. From docs/research/finxplorer-ingredients.md (option B rows), as generic components:
- A web host for signed-in users at scale: sessions tied to `mojoui.accounts` (not a URL id), many users per
  process, idle sessions dropped and restored, crawlable first paint.
- Charts: Sankey/flow, donut, calendar heatmap (Flint), on GTK and the web first.
- A bottom sheet / drawer, and a floating tab bar shell for phones.
- omxqua's Money·Ledger family as a theme beside Graphite.
- PWA install from the web host.
