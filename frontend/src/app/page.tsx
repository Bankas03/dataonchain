import Link from "next/link";

// The public home page: what dataonchain is, why it is built on Arc, the Arc
// and Circle tools behind it, what is done, and what comes next.

const NAV = [
  { href: "#about", label: "About" },
  { href: "#why-arc", label: "Why Arc" },
  { href: "#tools", label: "Built with" },
  { href: "#milestones", label: "Milestones" },
  { href: "#roadmap", label: "Roadmap" },
];

const HOW = [
  { title: "Sign up with your email", text: "No seed phrase, no browser extension. A USDC wallet on Arc is created for you the moment you confirm your email." },
  { title: "Get a price in USDC", text: "Pick MTN, Airtel, Glo or 9mobile, airtime or a data plan. We show the naira value and the exact USDC price, held for 10 minutes." },
  { title: "Pay and it is delivered", text: "Pay from your wallet with one tap. The payment settles on Arc and the airtime or data goes straight to the phone." },
  { title: "Refunded if it fails", text: "If a network cannot deliver, your USDC goes back to your wallet automatically. Every step is shown on the order page." },
];

const WHY_ARC = [
  {
    title: "Fees are paid in USDC",
    text: "On Arc the network fee is paid in USDC, not in a separate gas token. Our users only ever hold one thing, digital dollars, and costs are predictable in dollars. On top of that, we sponsor the fee, so users pay nothing extra.",
  },
  {
    title: "Final in under a second",
    text: "Arc settles a payment in under a second, and once settled it cannot be reversed. That is what lets us start delivering airtime the moment you pay, and why a refund, once sent, is final.",
  },
  {
    title: "Built by the issuer of USDC",
    text: "Arc comes from Circle, the company behind USDC and EURC. Wallets, gas sponsorship, crosschain transfers and swaps all come from the same family of tools, so a small team can build what used to need a large one.",
  },
  {
    title: "Made for stablecoin payments",
    text: "Arc is designed for everyday payments and currency exchange between stablecoins. Buying airtime and data is the most everyday payment there is in Nigeria, which makes it a natural fit.",
  },
];

const TOOLS = [
  { name: "Arc network", text: "Where every payment, refund and swap settles. Each one links to the Arc explorer so anyone can verify it." },
  { name: "USDC", text: "The digital dollar users pay with, and the currency Arc uses for its own network fees." },
  { name: "Circle Wallets", text: "A smart contract wallet created for every user at sign up, so people who have never used crypto can start in a minute." },
  { name: "Circle Gas Station", text: "Pays the network fee for our users' smart wallets. Nobody needs gas to buy airtime." },
  { name: "Circle Gateway", text: "One USDC balance that moves to seven other networks: Base, Arbitrum, Ethereum, Avalanche, OP, Polygon and Unichain, with no gas needed on any of them." },
  { name: "App Kit", text: "Powers swaps between USDC, EURC and cirBTC on Arc, with a guaranteed minimum on every swap." },
  { name: "EURC and cirBTC", text: "More than dollars: users can hold and swap into euro stablecoins and Bitcoin on Arc." },
];

const MILESTONES = [
  { title: "Email sign up with an automatic wallet", text: "Confirmed email, then a USDC wallet on Arc created automatically." },
  { title: "Live naira and USDC pricing", text: "A live exchange rate, prices held for 10 minutes, and a clear service fee." },
  { title: "Airtime and data paid with USDC", text: "MTN, Airtel, Glo and 9mobile, paid on Arc and delivered through our VTU partner's test environment." },
  { title: "Instant status and automatic refunds", text: "Orders update in seconds, and failed deliveries are refunded to the wallet without anyone asking." },
  { title: "Smart wallets with no network fees", text: "Every user moved to a smart wallet with sponsored gas; existing balances moved across automatically." },
  { title: "Send USDC to seven networks", text: "Crosschain transfers through Circle Gateway, a personal wallet on each network, and Move to Arc to bring it all home." },
  { title: "Every transfer recorded and checked", text: "Each step from deposit to mint is recorded, stuck transfers raise alerts, and a daily report checks every transfer against Circle." },
  { title: "Swaps on Arc", text: "USDC, EURC and cirBTC, with a fee shown upfront and a minimum you are guaranteed." },
  { title: "Admin dashboard and security review", text: "Full operations dashboard, a code audit, and the fixes that came from it, including password reset." },
  { title: "Public testing on Arc Testnet", text: "Early testers using the platform and shaping it with their feedback." },
];

const ROADMAP = [
  { title: "Company registration", text: "Registering dataonchain with the Corporate Affairs Commission (CAC) in Nigeria.", status: "In progress" },
  { title: "Live airtime and data delivery", text: "Connecting a live VTU provider once registration is complete.", status: "Next" },
  { title: "Bridge and swaps on Arc mainnet", text: "Moving crosschain transfers and swaps from Arc Testnet to Arc mainnet.", status: "Next" },
  { title: "Full launch on Arc mainnet", text: "Real USDC payments for airtime and data, for everyone in Nigeria.", status: "Planned" },
  { title: "Easier ways to add and cash out USDC", text: "Simple on and off ramps between naira and USDC.", status: "Planned" },
  { title: "Paying providers directly on Arc", text: "Settling with VTU providers in USDC on Arc as they start to accept it.", status: "Planned" },
];

function SectionTitle({ id, kicker, title, text }: { id: string; kicker: string; title: string; text?: string }) {
  return (
    <div id={id} className="scroll-mt-24">
      <p className="text-sm font-semibold uppercase tracking-wider text-emerald-700 dark:text-emerald-400">{kicker}</p>
      <h2 className="mt-2 text-3xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">{title}</h2>
      {text ? <p className="mt-3 max-w-2xl text-lg leading-relaxed text-zinc-600 dark:text-zinc-400">{text}</p> : null}
    </div>
  );
}

export default function Home() {
  return (
    <main className="min-h-screen bg-zinc-50 dark:bg-zinc-950">
      <header className="sticky top-0 z-20 border-b border-zinc-200/70 bg-zinc-50/90 backdrop-blur dark:border-zinc-800 dark:bg-zinc-950/90">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-3">
          <Link href="/" className="font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <nav className="hidden gap-5 text-sm text-zinc-600 md:flex dark:text-zinc-400">
            {NAV.map((n) => (
              <a key={n.href} href={n.href} className="hover:text-zinc-900 dark:hover:text-zinc-100">
                {n.label}
              </a>
            ))}
          </nav>
          <div className="flex gap-2">
            <Link href="/login" className="rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:text-zinc-300 dark:hover:bg-zinc-900">
              Log in
            </Link>
            <Link href="/signup" className="rounded-lg bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-800">
              Sign up
            </Link>
          </div>
        </div>
      </header>

      {/* Hero */}
      <section className="mx-auto max-w-5xl px-4 pb-16 pt-16 sm:pt-24">
        <p className="inline-flex items-center gap-2 rounded-full border border-amber-300 bg-amber-50 px-3 py-1 text-xs font-medium text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
          <span className="h-1.5 w-1.5 rounded-full bg-amber-500" />
          Public testing on Arc Testnet: test USDC only, no real money
        </p>
        <h1 className="mt-6 max-w-3xl text-4xl font-semibold tracking-tight text-zinc-900 sm:text-6xl dark:text-zinc-50">
          Buy airtime and data with USDC.
        </h1>
        <p className="mt-5 max-w-2xl text-lg leading-relaxed text-zinc-600 dark:text-zinc-400">
          Top up any MTN, Airtel, Glo or 9mobile line in seconds. Paid in USDC on Arc, delivered to the phone, refunded
          automatically if anything goes wrong.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <Link href="/signup" className="rounded-lg bg-emerald-700 px-5 py-3 font-medium text-white hover:bg-emerald-800">
            Create an account
          </Link>
          <a
            href="#about"
            className="rounded-lg border border-zinc-300 px-5 py-3 font-medium text-zinc-900 hover:bg-white dark:border-zinc-700 dark:text-zinc-100 dark:hover:bg-zinc-900"
          >
            Learn about the project
          </a>
        </div>
        <dl className="mt-14 grid grid-cols-2 gap-6 border-t border-zinc-200 pt-8 sm:grid-cols-4 dark:border-zinc-800">
          {[
            ["4", "Nigerian networks"],
            ["8", "blockchains connected"],
            ["0", "network fees for users"],
            ["< 1 s", "settlement on Arc"],
          ].map(([value, text]) => (
            <div key={text}>
              <dt className="text-3xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-50">{value}</dt>
              <dd className="mt-1 text-sm text-zinc-500">{text}</dd>
            </div>
          ))}
        </dl>
      </section>

      {/* About */}
      <section className="border-t border-zinc-200 bg-white py-20 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle
            id="about"
            kicker="About"
            title="Digital dollars for everyday spending"
            text="Many Nigerians already hold dollar stablecoins, but spending them on daily needs still means selling to someone, waiting, and paying fees along the way. dataonchain lets you spend USDC directly on the thing you buy most often: airtime and mobile data. You sign up with an email, we handle the blockchain, and the top up lands on the phone."
          />
          <ol className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
            {HOW.map((h, i) => (
              <li key={h.title} className="rounded-xl border border-zinc-200 p-5 dark:border-zinc-800">
                <span className="flex h-8 w-8 items-center justify-center rounded-full bg-emerald-700 text-sm font-semibold text-white">{i + 1}</span>
                <h3 className="mt-4 font-semibold text-zinc-900 dark:text-zinc-50">{h.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{h.text}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* Why Arc */}
      <section className="py-20">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle
            id="why-arc"
            kicker="Why Arc"
            title="Why we are building on Arc"
            text="A payment for airtime has to be cheap, instant and simple, or nobody will use it. Arc, the blockchain built by Circle for stablecoin payments, gives us all three."
          />
          <div className="mt-12 grid gap-5 sm:grid-cols-2">
            {WHY_ARC.map((w) => (
              <div key={w.title} className="rounded-xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
                <h3 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">{w.title}</h3>
                <p className="mt-2 leading-relaxed text-zinc-600 dark:text-zinc-400">{w.text}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Tools */}
      <section className="border-y border-zinc-200 bg-white py-20 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle
            id="tools"
            kicker="Built with"
            title="The Arc and Circle tools behind dataonchain"
            text="Everything a user touches runs on these building blocks. They are why a small team could get from an idea to a working product with wallets, crosschain transfers and swaps."
          />
          <div className="mt-12 grid gap-px overflow-hidden rounded-xl border border-zinc-200 bg-zinc-200 sm:grid-cols-2 lg:grid-cols-3 dark:border-zinc-800 dark:bg-zinc-800">
            {TOOLS.map((t) => (
              <div key={t.name} className="bg-white p-6 dark:bg-zinc-900">
                <h3 className="font-semibold text-emerald-800 dark:text-emerald-300">{t.name}</h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{t.text}</p>
              </div>
            ))}
            <div className="hidden bg-white p-6 sm:block dark:bg-zinc-900" />
            <div className="hidden bg-white p-6 lg:block dark:bg-zinc-900" />
          </div>
        </div>
      </section>

      {/* Milestones */}
      <section className="py-20">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle id="milestones" kicker="Milestones" title="What we have built so far" text="All of this is live today on Arc Testnet, open for anyone to test." />
          <ol className="mt-12 grid gap-x-10 sm:grid-cols-2">
            {MILESTONES.map((m) => (
              <li key={m.title} className="flex gap-4 border-b border-zinc-200 py-5 dark:border-zinc-800">
                <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-emerald-700 text-xs font-bold text-white">✓</span>
                <div>
                  <h3 className="font-semibold text-zinc-900 dark:text-zinc-50">{m.title}</h3>
                  <p className="mt-1 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{m.text}</p>
                </div>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* Roadmap */}
      <section className="border-t border-zinc-200 bg-white py-20 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle id="roadmap" kicker="Roadmap" title="What comes next" text="The road from public testing to a live product for everyone in Nigeria." />
          <ol className="relative mt-12 space-y-8 border-l-2 border-zinc-200 pl-8 dark:border-zinc-800">
            {ROADMAP.map((r) => (
              <li key={r.title} className="relative">
                <span
                  className={`absolute -left-[41px] top-1 h-4 w-4 rounded-full border-2 ${
                    r.status === "In progress"
                      ? "border-amber-500 bg-amber-400"
                      : r.status === "Next"
                        ? "border-emerald-600 bg-white dark:bg-zinc-900"
                        : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900"
                  }`}
                />
                <div className="flex flex-wrap items-center gap-3">
                  <h3 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">{r.title}</h3>
                  <span
                    className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${
                      r.status === "In progress"
                        ? "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
                        : r.status === "Next"
                          ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                          : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                    }`}
                  >
                    {r.status}
                  </span>
                </div>
                <p className="mt-1 text-zinc-600 dark:text-zinc-400">{r.text}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* Call to action */}
      <section className="py-20">
        <div className="mx-auto max-w-5xl px-4">
          <div className="rounded-2xl bg-emerald-800 px-6 py-12 text-center sm:px-12">
            <h2 className="text-3xl font-semibold tracking-tight text-white">Help us test it</h2>
            <p className="mx-auto mt-3 max-w-xl text-emerald-100">
              Create an account, get free test USDC, and try buying airtime, sending USDC to another network or swapping on
              Arc. Your feedback shapes the launch.
            </p>
            <div className="mt-8 flex flex-wrap justify-center gap-3">
              <Link href="/signup" className="rounded-lg bg-white px-5 py-3 font-medium text-emerald-900 hover:bg-emerald-50">
                Create an account
              </Link>
              <Link href="/login" className="rounded-lg border border-emerald-500 px-5 py-3 font-medium text-white hover:bg-emerald-700">
                Log in
              </Link>
            </div>
          </div>
        </div>
      </section>

      <footer className="border-t border-zinc-200 py-8 dark:border-zinc-800">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-4 text-sm text-zinc-500">
          <span>© {new Date().getFullYear()} dataonchain · Built on Arc</span>
          <span>Currently on Arc Testnet. Test USDC has no value.</span>
        </div>
      </footer>
    </main>
  );
}
