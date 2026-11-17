# Atrium PC server — Asian Dramas integration

This guide is for **Claude Code running in the actual local Atrium server project on the Windows PC**. The GitHub Pages repository `Jeysxn9321/Atrium` currently contains the standalone web application, **not** the PC server source. Do not mistake editing `index.html` on GitHub for modifying the running server.

## Objective
Implement **one** first-class section named **Asian Dramas** on the PC-hosted Atrium server and its desktop frontend, using the same architecture, components, navigation, player, data flow, caching, and account integration already used by Movies, TV Shows, and Animes. It must appear after Home in the top navigation.

Inside Asian Dramas provide **All / Korean / Japanese** filters, not separate top-level K-drama and J-drama tabs. The home page should display just one **Asian Dramas** shelf combining both. Keep K-dramas and J-dramas browseable within that single section.

## Start by inspecting the local code
1. Find the actual running server entry point, frontend assets/templates, routes, API handlers, Stremio authentication, installed add-on discovery, catalog adapters, player integration, resume/history, My List, and search.
2. Determine how the desktop version serves its own frontend and whether the mobile/GitHub Pages site is a separate client. Preserve both existing deployment paths.
3. Reuse the app's **existing abstractions**. Do not replace files wholesale, create a second app/server, hardcode fake content, or disturb the working Movies/TV Shows/Animes/Somnia paths.
4. Inspect the current GitHub `main` implementation of the `Asian Dramas` section as a reference, but adapt it to the PC server's real architecture.

## Data
- Load the **installed Stremio add-ons from the account already configured in Atrium** using the server's authenticated Stremio code. Never ask for or store credentials in committed code, and never expose configured add-on URLs/tokens in client responses or logs.
- Inspect each installed add-on manifest. Use `catalogs`, resource support, accepted extra fields, catalog IDs/types, and genre/locale options to discover Korean, Japanese, and combined Asian drama catalog feeds. Do not assume all installed add-ons are catalog providers: stream-only add-ons do not have browsable titles.
- Fetch catalog results through a server-side service using the existing request/cache/error conventions. Handle `search`, `skip`, and `genre` only when the manifest declares support. Respect provider timeouts/rate limits and sanitise input.
- Build one normalized metadata shape accepted by Atrium's existing cards and details. Deduplicate by canonical title ID, falling back to source-specific IDs when necessary. Preserve add-on origin privately for later metadata and stream lookups.
- For known IMDb IDs, reuse the existing Cinemeta/TMDB enrichments; for non-Cinemeta IDs, query the originating add-on's `meta` resource. Never invent posters, seasons, ratings, streaming availability, or ranking.
- Protect against server-side request forgery and credential leaks when fetching installed add-on URLs. Validate scheme and host; prevent private-network/loopback targets unless explicitly trusted by existing server policy.

## UI and interactions
- Add **Asian Dramas** to the same navigation system as the existing sections (desktop, TV, mobile if sharing UI), with one combined shelf on Home.
- Within the section, present All, Korean, Japanese filters; use the same poster cards, carousel arrows, keyboard/controller navigation, responsive layout, loading skeletons, pagination, empty/error states, search, detail panels, season and episode UX, My List, Continue Watching and watched-state behavior as other sections.
- Only offer sorting (popular, recently added, ratings) if the installed provider or existing canonical metadata actually supports the sort; never label a generic list `Trending` without ranking data.
- Keep My List and history functional for non-IMDb IDs supported by Stremio. Reuse existing stored item shapes and ID validation with safe validation for other add-on ID formats.
- Search from the Asian Dramas page should search the drama catalogs and maintain the selected All/Korean/Japanese filter.
- Use existing play/versions/download handlers and supported stream add-ons; do not independently bypass DRM or licensing. A catalogue record is not evidence of playable streams. Handle no-source results clearly.
- Avoid introducing duplicate country-specific top-level tabs or separate pages; no duplicate Asian dramas shelves on Home.

## Validation on the PC
- Start the actual local Atrium server and open the desktop client.
- Confirm Asian Dramas appears alongside the other sections in the **PC-hosted** Atrium (not merely the GitHub Pages version), and the Home shelf is present.
- Confirm Korean and Japanese catalogs appear from the signed-in account when compatible add-ons exist; verify search, filter, poster, detail, seasons, My List, player source selection, and resume.
- Test no add-ons, stream-only add-ons, CORS-restricted providers, network failure, invalid/stale account, and duplicate titles.
- Verify the previous Movies, TV Shows, Animes and Somnia routes still work, and no account secrets have entered the repository.
- Run the project's existing tests and build, fix errors, and report what passed or what was blocked by missing access.

The public site was updated in `Jeysxn9321/Atrium`. **The local server project must be updated separately.** The finished result should work from the server-hosted desktop URL and not require opening GitHub Pages.
