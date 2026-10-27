# dataonchain admin dashboard

A separate Next.js website for the admin, at `https://dashboard.dataonchain.online`
(Vercel project `dataonchain-admin`, Root Directory `admin`).

- Every `/api/*` request is passed through to the backend (`API_URL`), so the
  admin login cookie belongs to this website only.
- Only the email in `ADMIN_EMAIL` (set on Render) can log in: password, then a
  6 digit code emailed to that address. First time: use "Forgot password" to set
  the password.
- The admin API lives in `backend/src/admin`.

Local:

```bash
cp .env.example .env.local   # API_URL=http://localhost:4000
npm install
npm run dev                  # http://localhost:3001
```
