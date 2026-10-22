# CHS Spin Game

A redesigned version of the CHS "Spin for a chance to Win" booth game, built with React and Vite. It keeps the CHS brand colours and logo.

## Run it

```bash
npm install
npm run dev
```

Open http://localhost:5173. The admin page is at http://localhost:5173/admin. It is not linked from the game, so share that address only with staff.

To build static files for hosting (Netlify, Vercel, GitHub Pages, etc.):

```bash
npm run build
```

Upload the `dist/` folder.

## How the game works
1. The player enters their name and email, and the game emails them a **6-digit code**. Emails that have already played are blocked before a code is sent.
2. They enter the code. The database only registers an email after its code has been verified.
3. A popup explains the rules (one spin, one question, 20-second timer, jackpot).
4. They spin the wheel. It lands on a topic and they answer one question.
5. A correct answer wins a prize. Prizes come from the stock tiers in `src/config.js`. Landing on the jackpot wins the mystery prize, and the jackpot can only be won once until it's reset.
6. The result screen stays locked on that device, so they can show it at the booth.

**One spin per email, one spin per device.** An email that has already played can't log in again (the check ignores upper/lower case). A device that has already played shows a "you've already played" screen, even after a refresh.

## Shared database (needed when players use their own phones)
Without it, entries are saved only in the browser of the device running the game. With it, every phone checks the same list, so one email gets one spin no matter which phone it's used on.

The player list is protected. The tables are locked, and the game can only call a few database functions. Players can never see other players' emails, and the admin list needs the password, which the database checks.

### 1. Create the Supabase project (about 5 minutes, free)
1. Sign up at https://supabase.com and click **New project**. Pick a region close to the event, such as **West EU (Ireland)**.
2. Open `supabase/schema.sql` and change `change-this-password` (near the bottom) to your admin password.
3. In Supabase, open **SQL Editor → New query**, paste the whole file and click **Run**. It should say "Success. No rows returned".
4. Go to **Project Settings → API** and copy the **Project URL** and the **anon public** key.

### 1b. Turn on the 6-digit email code
In Supabase:
1. **Authentication → Sign In / Providers → Email**: make sure Email is enabled and **Email OTP Length** is `6`. Click **Save**.
2. **Authentication → Emails → Templates**: open **Magic Link** and paste in the contents of `supabase/email-template.html`. Set the subject to `Your CHS Career Spin code: {{ .Token }}`. Do the same for **Confirm signup**. The template must contain `{{ .Token }}`, otherwise players get a link instead of a code.
3. **Set up SMTP (required for the event).** Supabase's built-in email only sends a few emails per hour, which isn't enough for a booth. See "Email sending (SMTP)" below.
4. **Authentication → Rate Limits**: raise **Rate limit for sending emails** to about `300` per hour.

### 2. Connect the game
Copy `.env.example` to `.env` and paste in the two values:

```
VITE_SUPABASE_URL=https://xxxx.supabase.co
VITE_SUPABASE_ANON_KEY=eyJ...
```

Restart `npm run dev`. The admin page badge should now read **All devices**.

### 3. Put it online so phones can open it
Phones can't open `localhost`, so the game needs a public web address:

```bash
npm run build
```

Then go to https://app.netlify.com/drop and drag the `dist` folder onto the page. You'll get a link like `https://chs-career-spin.netlify.app`. Open it and use **Get QR code** to print the QR for the booth.

The Supabase settings are baked in when you build. If you change `.env`, run `npm run build` again and re-upload.

### Email sending (SMTP)
In Supabase, go to **Authentication → Emails → SMTP Settings**, turn on **Enable custom SMTP** and fill in the fields for one of the options below.

**Option A: Outlook with a Microsoft 365 work mailbox (works until the end of December 2026)**

Personal Outlook.com/Hotmail addresses **cannot** be used. Microsoft only allows OAuth sign-in for them, and Supabase needs a username and password. A company Microsoft 365 mailbox works if your IT admin enables it first:

1. *Admin:* Microsoft 365 admin center → **Users → Active users** → select the sending mailbox (a shared one like `events@yourcompany.com` is best) → **Mail** tab → **Manage email apps** → tick **Authenticated SMTP** → Save.
2. *Admin:* Exchange admin center → **Settings → Mail flow**: make sure **"Turn off SMTP AUTH protocol for your organization"** is **unticked**.
3. *Admin:* if **Security defaults** are on in Microsoft Entra, password-based SMTP is blocked. The mailbox needs to be excluded via Conditional Access, or use Option B.
4. In Supabase SMTP Settings:

| Field | Value |
|---|---|
| Sender email | the mailbox address, e.g. `events@yourcompany.com` |
| Sender name | `CHS Spin Game` |
| Host | `smtp.office365.com` |
| Port | `587` |
| Username | the same mailbox address |
| Password | that mailbox's password |
| Minimum interval | `1` second |

5. Test by playing once with your own email. If no code arrives, check **Authentication → Logs** in Supabase for the SMTP error.

Microsoft plans to switch off password-based SMTP for Microsoft 365 after December 2026, so use Option B for events after that.

**Option B: Brevo (free, about 300 emails/day, works long-term)**

1. Sign up at https://www.brevo.com, then go to **Senders, Domains & Dedicated IPs** and verify the sender address you'll send from.
2. Go to **SMTP & API → SMTP** and generate an SMTP key.
3. In Supabase: Host `smtp-relay.brevo.com`, Port `587`, Username = your Brevo SMTP login, Password = the SMTP key, Sender email = the address you verified.

**Option C: Gmail (free, up to about 500 emails/day)**

1. Use a dedicated Gmail account for the event, e.g. `chs.careerspin@gmail.com`.
2. Turn on **2-Step Verification**: https://myaccount.google.com/security
3. Create an App Password at https://myaccount.google.com/apppasswords. Name it `CHS Career Spin` and copy the 16-character password; Google only shows it once.
4. In Supabase SMTP Settings: Host `smtp.gmail.com`, Port `587`, Username = the full Gmail address, Password = the 16-character app password with no spaces, Sender email = the same Gmail address, Sender name `CHS Career Spin`.

### After the event
Download the CSV from the admin page, then pause or delete the Supabase project so the player data isn't kept longer than needed (GDPR). Verified emails are also stored under **Authentication → Users**, and deleting the project removes them too.

## Customise
- Questions and topics: `src/data.js`
- Prize stock and prize tiers: `src/config.js` (in shared mode, change live stock from the admin page)
- Admin password: `supabase/schema.sql` in shared mode, `src/config.js` in local mode
- Colours and animations: `src/styles.css` (brand tokens are at the top)
- Music and sound effects: `src/lib/sound.js`. They're generated in code, so there are no audio files. Players can mute with the speaker button.
