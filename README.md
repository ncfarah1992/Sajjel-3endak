# Sajjel 3endak

Card game scorebook, starting with Leekha. Installable web app: open it on the phone and choose "Add to Home Screen".

Files
- `index.html`: the app
- `manifest.webmanifest`, icons: home-screen install
- `sw.js`: offline support (bump VERSION when index.html changes)
- `supabase-setup.sql`: run once in Supabase > SQL Editor to switch on online sync
- `.github/workflows/keepalive.yml`: pings Supabase every 3 days so the free project does not pause

Online sync: set `SUPA_URL` and `SUPA_KEY` (publishable key) near the "online sync" section of index.html.
