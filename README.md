# dataonchain

Buy Nigerian airtime and data with USDC on Arc.

| Folder | What it is | Runs on | Hosted on |
| --- | --- | --- | --- |
| `frontend/` | Next.js website | http://localhost:3000 | Vercel |
| `backend/` | Hono API, Turso database, Circle, VTpass | http://localhost:4000 | Render |
| `setup/` | Setup and deploy scripts | | |

## Run locally

```bash
bash setup/dev.sh
```

Starts the backend and frontend together. Press Ctrl+C to stop both.

## Settings

- `backend/.env` holds every secret (database, Circle, VTpass). See `backend/.env.example`.
- `frontend/.env.local` holds public settings only, such as the API address. See `frontend/.env.example`.
- Never commit a real `.env` file.

## Database

```bash
cd backend
npm run db:generate   # after changing src/db/schema.ts
npm run db:migrate    # apply changes to the development database
npm run db:check      # confirm every table exists
npm run db:studio     # browse the data
```
