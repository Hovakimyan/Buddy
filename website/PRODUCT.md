# Buddy marketing website
Buddy is a Mac companion for Claude Code, displaying session state and permission requests around the notch. Block is its expressive blue character. Buddy never approves automatically; unanswered requests return to the terminal. An optional iPhone companion uses private iCloud and requires signed builds and the same Apple Account; verified on a real iPhone (iCloud, push, Face ID, notification actions, messages to Claude). Codex and other agents are planned. The source is public on GitHub. The Mac app is distributed as a notarized dmg from GitHub Releases (the site's Download for Mac link takes the latest release's Buddy.dmg); the iPhone app is headed for the App Store.

Audience: developers using Claude Code on macOS. Make the companion understandable through an interactive sample, then lead to the download.

User direction: replace the conventional landing page with a creative, interactive experience. Concept: a miniature leave-your-desk adventure: Mac session, request, optional phone handoff, visitor decision. Demonstrations must be identified as simulations. Preserve blue Block character and honest availability.

Hosting: Railway at https://buddy.ashoon.dev (website/Dockerfile and Caddyfile, service Root Directory `website`, deployed from main), DNS in Cloudflare; setup in docs/releasing.md, "Website: Railway and Cloudflare". The domain may change later; update the canonical and og URLs in index.html, privacy.html and support.html, the Railway custom domain and the DNS record together.
