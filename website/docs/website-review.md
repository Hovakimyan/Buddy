# Website review — 23 October 2026

## Scope and evidence
Reviewed the HTML/CSS/JavaScript against the Swift character state model, character drawing/pose code, question card model, plan card, and session focus logic. Browser verification used Chromium with desktop and emulated mobile/landscape viewports; not physical iOS Safari. This is a scoped product and usability review, not a WCAG certification or legal clearance.

## Findings and changes

- **P1: Small decision targets in scaled phone. Fixed.** Added equivalent, unscaled Allow/Decline/Replay controls with 44px minimum height. The phone remains an illustrative view of the same state. Focus moves to the larger replay control after a decision.
- **P1: Incomplete approval-mode explanation. Fixed.** Plan review supports an explicit auto-accept-edits choice. Copy now distinguishes that user choice from Buddy making approvals autonomously. Plan example is explicitly Mac-only.
- **P2: Character coverage and fidelity. Improved.** Previously three moods and an always-blue character hid most of the implementation. Added all 11 states and eight transient expressions, with state colors based on Block.swift. These are CSS illustrations, not exact Swift renderings. Listening is an expression, not a microphone feature. Defined emotes are demonstrated without claiming that all trigger automatically in current app workflows.
- **P2: Feature coverage. Improved.** Added working sample question answers, three plan decisions, and session switching. Sample data and no-backend behavior are disclosed next to the controls.
- **P2: Long pinned story. Improved.** Added visible Skip story and a keyboard skip link directly to the feature section.
- **P2: Heading hierarchy and small navigation text. Improved.** Corrected phone heading level and increased scene navigation, skip, and status label text. Miniature device text remains decorative-scale; primary task controls and explanatory copy exist outside the scaled device.

## Remaining priorities

1. **P1 before public launch: release destination.** Project/installation links may require repository access. No public signed/notarized download or App Store release exists. The site should gain a real release CTA once distribution is ready.
2. **P1 product verification: iPhone path.** Real-device iCloud, push, and Face ID verification remains pending. Keep development caveats prominent; the web simulation proves no native connectivity.
3. **P2: physical-device and assistive-technology coverage.** Check Safari sticky positioning, dynamic browser toolbars, touch scrolling, VoiceOver, 200% zoom and enlarged text on real devices. Current automated evidence is Chromium, not a claim of universal compatibility.
4. **P2: maintainability.** CSS has accumulated responsive overrides. Consolidate the original fixed-stage rules and new pinned-story rules before further structural redesigns. Avoid adding a framework simply to clean this up.
5. **P2: exact app visuals.** Use native captures or shared character fixtures before presenting the web character as a pixel-accurate reproduction. Browser illustrations currently disclose this distinction.
6. **Hosting removal requested.** Hosted project lookup is accessible again. The available connector cannot delete or unpublish it; remote deletion remains unconfirmed. Removed the local hosting manifest and preview links. Do not redeploy without an explicit request.

## Browser checks
All 11 states, eight expression selections, question/plan/session choices and reset, Allow/Decline/Replay through unscaled controls, 320×568 / 390×844 / 844×390 layouts, no horizontal overflow, reduced-motion suppression, and no observed page errors passed. Desktop character and action sections and mobile decision scene were visually inspected. Detector warnings about miniature device labels were reviewed separately from functional controls; polygon warnings refer to intentional heart/star eye geometry, not a photo cutout.

## Resemblance and branding

The exact reference characters were not supplied, and several unrelated products share likely names, so no definitive visual or legal conclusion is justified.

One identified reference, https://moch.im/, describes a soft-body companion and depicts a green ovoid with round eyes and a small mouth. Buddy uses a rounded block and app-state color changes. Those are observable differences, not legal clearance. Code drawn locally does not itself establish that a design is independent of someone else's artwork.

A generic companion concept is different from copying a specific expressive character. Copyright does not protect ideas themselves: https://copyright.gov/help/faq/faq-protect.html . Trademark analysis also considers whether similar marks for related goods could confuse customers about source: https://www.uspto.gov/page/about-trademark-infringement . A full clearance search goes beyond identical names: https://www.uspto.gov/trademarks/search/comprehensive-clearance-search-similar-trademarks . These are US references; jurisdiction and the actual reference design matter.

Before public release: compare supplied references side by side (silhouette, eye construction, proportions, movement, palette, voice, sound and icon), document source/provenance for artwork and sounds, and clear the Buddy/Block names in intended markets. Distinctive native-app character traits should be designed in the app and carried through to the website, rather than changing marketing art alone. No competitor logos, names, or affiliation claims have been added to the website.

## Responsive follow-up

Checked 320×568, 375×667, 390×844, 430×932, 768×1024, 1024×768, 1440×900, 1920×1080, and 844×390 in Chromium. No document horizontal overflow or caption/footer overlap was found in these checks. Visual review caught the short-phone illustration touching the heading and cramped tablet feature columns; corrected both. At viewport heights of 350px or less, the introduction uses normal document flow and scene buttons rather than pinning an unreadable stage. Verified this at 640×300, plus 720×450, and tested approval/replay and plan controls. A 20px minimum text-size stress check at 390px width did not produce horizontal overflow; this is not equivalent to comprehensive browser zoom or text-only zoom testing. Physical touch/Safari/VoiceOver checks remain outstanding.
