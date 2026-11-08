# RedApp for Android (native Kotlin + Jetpack Compose)

Native rewrite of RedApp. No WebView, no HTML wrapper. The website in the repo root is untouched.
This folder adds `android/` (the app), `supabase/` (backend) and `.github/workflows/android.yml` (APK builds).

**Status: source complete, never compiled.** It was written without an Android SDK or network, so expect a few
compile errors on the first build (API names in supabase-kt / LiveKit are the likeliest). Section 5 explains how to
get them fixed quickly.

## Architecture
| Need | Solution |
|---|---|
| Accounts (no email/SMS) | Supabase Auth, username + password (username mapped to a placeholder email, confirmation off) |
| Real-time chat, receipts, presence | Supabase Postgres + Realtime, protected by row-level security (`supabase/schema.sql`) |
| Images, video, files, voice | Supabase Storage, private bucket, short-lived signed URLs |
| 1:1 + group voice/video calls | LiveKit Cloud (WebRTC SFU). Join tokens come from the `livekit-token` Edge Function after a membership check |
| Screen sharing | `MediaProjection` -> LiveKit screen-share track, with a mediaProjection foreground service |
| Multiple accounts | Sessions of every account kept in `EncryptedSharedPreferences` (Android Keystore); switching imports that session. Chats live server-side per user; settings are namespaced per account id |
| Push | Firebase Cloud Messaging, sent by the `push` Edge Function (optional until configured) |

## 1. Backend setup (about 15 minutes, all free tiers)
1. **Supabase**: create a project at supabase.com.
   - SQL Editor > paste `supabase/schema.sql` > Run.
   - Authentication > Providers > Email: **turn OFF "Confirm email"** (this is what makes sign-up instant, no verification).
   - Project Settings > API: copy the **Project URL** and the **anon public key**.
2. **LiveKit**: create a project at cloud.livekit.io. Copy the **WebSocket URL** (`wss://...livekit.cloud`), **API key**, **API secret**.
3. **Edge Functions** (needs the Supabase CLI: `npm i -g supabase`, then `supabase login`, `supabase link --project-ref YOUR_REF`):
   ```
   supabase secrets set LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...
   supabase functions deploy livekit-token
   ```
4. **Push (optional)**: create a Firebase project, add an Android app with package `com.redapp.app`, download `google-services.json`
   into `android/app/`. Firebase console > Project settings > Service accounts > Generate key, then
   `supabase secrets set FCM_SERVICE_ACCOUNT='<the JSON>'`, `supabase functions deploy push --no-verify-jwt`, and in Supabase
   Database > Webhooks create two webhooks (tables `messages` and `calls`, event INSERT) pointing at the `push` function.
   Without this the app works fully, minus notifications while the app is closed.

## 2. Build the APK yourself
1. Install Android Studio, open the `android/` folder, let Gradle sync.
2. Copy `android/local.properties.example` to `android/local.properties` and fill in the three values.
3. Build > Build APK(s). Output: `android/app/build/outputs/apk/debug/app-debug.apk`.

## 3. Build it on GitHub and get a download link (recommended: this also makes updates work)
Updates only install over the old app if every build is signed with the **same key**. Create one once:
```
keytool -genkeypair -v -keystore redapp.jks -alias redapp -keyalg RSA -keysize 2048 -validity 10000
base64 -w0 redapp.jks      # copy the output
```
Keep `redapp.jks` and its passwords safe forever (losing it means users must uninstall to update).
In the repo: Settings > Secrets and variables > Actions, add: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `LIVEKIT_URL`,
`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, and optionally `GOOGLE_SERVICES_JSON`.
Then publish a version: `git tag v1.0.0 && git push origin v1.0.0`.
The APK appears at `https://github.com/redahajarlabubu-blip/RedApp.6/releases` (a permanent download link).

## 4. Install and update (for users)
- **Install**: open the Releases link on the phone, download `RedApp.apk`, tap it, allow "Install unknown apps" for the browser when asked, Install.
- **Update**: download the newest `RedApp.apk` the same way and open it; Android installs over the old version and keeps all accounts and chats.
- **Multiple accounts**: tap your name at the top of the chat list > Add account. Switch or remove accounts on the same screen.
- Find people by **username** (Contact discovery = search by username or name; there are no phone numbers).

## 5. Getting it compiled and tested (honest next steps)
Open the project with **Claude Code on your own computer** (it has the Android SDK and network) and say:
"Run `./gradlew assembleDebug` in android/, fix every compile error, then test on an emulator." The code is organised so
fixes are local: `data/Backend.kt` (Supabase), `call/CallSession.kt` (LiveKit), `ui/*` (screens).

## What is and is not done
Done in source: sign-up/sign-in without verification, multiple accounts, 1:1 and group chat, text/image/video/file/voice/sticker
messages, delivery and read receipts (double ticks), online and last seen, user search, voice and video calls (1:1 and group grid),
MediaProjection screen sharing, push plumbing, English/French/Spanish, the existing RedApp look.

**Not yet in the native app (present in the web version)**: QR-code linking, phone-number lookup, location sharing, the RedAI assistant
(needs an AI API key), per-chat mute/rename/clear, message requests and blocking, appearance settings, security-code verification.
**Security difference**: the web app used end-to-end encryption between two devices. This version uses TLS plus row-level security;
the server can read message text. End-to-end encryption can be added later (e.g. libsodium sealed keys per device) but is a project of its own.
Other limits: ringing needs push (or the app open) to alert the callee; voice recording is tap-to-start, tap-to-send; files up to 50 MB.
