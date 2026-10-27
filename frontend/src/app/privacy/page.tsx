import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Privacy Policy · dataonchain" };

export default function PrivacyPage() {
  return (
    <LegalPage
      title="Privacy Policy"
      updated="27 October 2026"
      intro={
        <p>
          This policy explains what personal data dataonchain collects, why, who it is shared with, how long it is kept, and
          the rights you have under the Nigeria Data Protection Act 2023. dataonchain is the data controller for your data.
          Our registration with the Corporate Affairs Commission is in progress; once it is complete, our registered name and
          address will appear here.
        </p>
      }
    >
      <h2>1. What we collect</h2>
      <ul>
        <li><strong>Account details:</strong> your name, email address, Nigerian phone number and password. Your password is stored only in scrambled (hashed) form; we cannot read it.</li>
        <li><strong>Wallet details:</strong> the addresses of the wallets created for you on Arc and on other networks, and their balances.</li>
        <li><strong>Orders:</strong> the phone numbers you top up, the network, the plan or amount, prices, and the delivery reference from our provider.</li>
        <li><strong>Transactions:</strong> your payments, refunds, transfers between networks and swaps, including their blockchain transaction records.</li>
        <li><strong>Technical data:</strong> your IP address and browser type when you log in or use the site, kept with your login session and in server logs for security.</li>
        <li><strong>Messages:</strong> what you send us on WhatsApp when you ask for help.</li>
      </ul>
      <p>We do not collect your BVN, NIN, bank details or card details at this stage.</p>

      <h2>2. Why we use it, and on what basis</h2>
      <ul>
        <li><strong>To provide the service</strong> (create your account and wallets, process purchases, refunds, transfers and swaps, send account emails): this is necessary to perform our contract with you.</li>
        <li><strong>To keep the service and users safe</strong> (prevent fraud and abuse, secure accounts, investigate problems): our legitimate interest in running a safe service.</li>
        <li><strong>To meet legal obligations</strong> (keeping financial records, responding to lawful requests from authorities): legal obligation.</li>
        <li><strong>To improve dataonchain</strong> (understanding how the service is used, fixing problems): our legitimate interest. We do not sell your data.</li>
        <li><strong>Marketing:</strong> we do not send marketing messages. If we ever do, we will ask for your consent first, and you can withdraw it at any time.</li>
      </ul>
      <p>We do not make decisions about you based only on automated processing that have legal or similarly significant effects.</p>

      <h2>3. Who we share it with</h2>
      <p>We share only what each provider needs to do its job for us:</p>
      <ul>
        <li><strong>Circle</strong> (United States): wallets, transfers between networks and swaps. Receives wallet and transaction details.</li>
        <li><strong>Our airtime and data provider</strong> (currently VTpass, Nigeria): receives the phone number, network and amount for each purchase.</li>
        <li><strong>Resend</strong> (United States): sends our emails (confirmation, password reset). Receives your name and email.</li>
        <li><strong>Render</strong> (servers in the European Union), <strong>Vercel</strong> (website hosting) and our cloud database provider: store and run the service, and so hold the data described above.</li>
        <li><strong>Authorities</strong>, when the law requires it.</li>
      </ul>

      <h2>4. Blockchains are public</h2>
      <p>
        Transactions on Arc and the other networks are recorded on public blockchains. Anyone can see wallet addresses,
        amounts and times. They do not show your name, email or phone number, but these records are permanent: neither we
        nor anyone else can change or delete them.
      </p>

      <h2>5. Transfers outside Nigeria</h2>
      <p>
        Some of our providers store or process data outside Nigeria (see section 3). We use providers that protect personal
        data to a standard similar to Nigerian law, and we transfer only what is needed to provide the service you asked for.
      </p>

      <h2>6. How long we keep it</h2>
      <ul>
        <li>Account and wallet details: while your account is open, and then for as long as the law requires us to keep financial records.</li>
        <li>Orders and transactions: for as long as the law requires us to keep financial records, then deleted or anonymised.</li>
        <li>Login sessions: until they expire or you log out. Server logs: for a short period, for security.</li>
        <li>WhatsApp messages: as long as needed to resolve your request.</li>
      </ul>

      <h2>7. Your rights</h2>
      <p>Under the Nigeria Data Protection Act 2023 you have the right to:</p>
      <ul>
        <li>be told how your data is used (this policy);</li>
        <li>get a copy of your personal data;</li>
        <li>have wrong or out of date data corrected;</li>
        <li>have your data deleted when it is no longer needed or there is no lawful basis to keep it (records we must keep by law, and public blockchain records, cannot be deleted);</li>
        <li>restrict or object to some uses of your data;</li>
        <li>withdraw consent where we rely on it;</li>
        <li>receive your data in a common electronic format;</li>
        <li>complain to the Nigeria Data Protection Commission (NDPC).</li>
      </ul>
      <p>To use any of these rights, message us on WhatsApp from the phone number on your account, or tell us your account email. We may need to confirm it is you before we act.</p>

      <h2>8. How we protect it</h2>
      <ul>
        <li>All connections to the website are encrypted (HTTPS).</li>
        <li>Passwords are hashed, emails are confirmed, and every wallet transfer needs your instruction or is a refund to you.</li>
        <li>Wallet keys are held by Circle&apos;s wallet service, never in our database.</li>
        <li>Access to our systems is limited and protected, and admin actions are logged.</li>
      </ul>
      <p>
        If a data breach is likely to put your rights at high risk, we will report it to the NDPC within 72 hours of
        learning about it, and tell you without delay what happened and what you should do.
      </p>

      <h2>9. Cookies and browser storage</h2>
      <p>
        We use one cookie to keep you logged in, and your browser remembers whether you chose light or dark mode. We do not
        use advertising or tracking cookies.
      </p>

      <h2>10. Children</h2>
      <p>dataonchain is not for anyone under 18. We do not knowingly collect data from children; if we learn we have, we delete it.</p>

      <h2>11. Changes to this policy</h2>
      <p>We may update this policy. The date at the top shows the latest version, and we will tell you on the website about significant changes.</p>
    </LegalPage>
  );
}
