import type { Metadata } from "next";
import Link from "next/link";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Terms of Service · dataonchain" };

export default function TermsPage() {
  return (
    <LegalPage
      title="Terms of Service"
      updated="28 October 2026"
      intro={
        <p>
          These terms are the agreement between you and dataonchain when you use our website and services. By creating an
          account or using the service, you agree to them. Please read them together with our{" "}
          <Link href="/privacy" className="text-emerald-700 underline dark:text-emerald-400">Privacy Policy</Link> and{" "}
          <Link href="/refund-policy" className="text-emerald-700 underline dark:text-emerald-400">Refund Policy</Link>.
        </p>
      }
    >
      <h2>1. Who we are</h2>
      <p>
        dataonchain is a service, based in Nigeria, that lets you buy airtime and mobile data for Nigerian phone lines and
        pay with USDC on the Arc blockchain. Our registration with the Corporate Affairs Commission (CAC) is in progress.
        When it is complete, this page will show our registered name and address.
      </p>

      <h2>2. Launch on Arc mainnet</h2>
      <p>dataonchain runs on Arc mainnet with real USDC. Features open step by step:</p>
      <ul>
        <li>Buying airtime and data opens after our company registration and a live provider are in place.</li>
        <li>Sending to other networks, sending to other wallets and swaps open when we announce them on the website.</li>
        <li>Limits apply while we launch, and features, limits and fees may change. We may pause a feature for maintenance or safety.</li>
      </ul>

      <h2>3. Who can use dataonchain</h2>
      <ul>
        <li>You must be at least 18 years old and able to enter into a binding agreement.</li>
        <li>You must give true details (name, email and Nigerian phone number) and keep them up to date.</li>
        <li>You must not use dataonchain where the law does not allow it, or on behalf of someone who is not allowed to use it.</li>
      </ul>

      <h2>4. Your account</h2>
      <ul>
        <li>You need a confirmed email address to buy, send or swap.</li>
        <li>Keep your password secret. You are responsible for what happens in your account unless it was caused by our failure.</li>
        <li>Tell us straight away on WhatsApp if you think someone else has used your account, and reset your password.</li>
      </ul>

      <h2>5. Your wallet</h2>
      <p>
        When you confirm your email, we create a smart wallet for you on Arc using Circle&apos;s wallet service. You do not
        get a seed phrase: dataonchain operates the wallet through Circle on your behalf. This means:
      </p>
      <ul>
        <li>We only move funds from your wallet when you ask (a purchase, a transfer or a swap), to return funds to you (a refund or moving to your new wallet), or when the law requires it.</li>
        <li>We also create wallets for you on the other supported networks when you first send to them. They work the same way.</li>
        <li>Only send USDC, EURC or cirBTC on Arc to your Arc wallet address. Tokens sent on another network, or other tokens, may be lost and we may not be able to recover them.</li>
        <li>Blockchain transactions are final. Once a payment or transfer is confirmed on the network, it cannot be reversed.</li>
      </ul>

      <h2>6. Buying airtime and data</h2>
      <ul>
        <li>Before you pay, we show the naira value, the exact USDC price, the exchange rate and our service fee. That price is held for 10 minutes.</li>
        <li>Check the phone number and the network before you pay. Airtime or data delivered to a valid number cannot be reversed.</li>
        <li>Delivery is done by our airtime and data provider and the mobile network. It usually takes seconds but can take longer when a network is slow.</li>
        <li>If delivery fails, you are refunded as set out in our Refund Policy.</li>
      </ul>

      <h2>7. Sending to other networks and wallets</h2>
      <ul>
        <li>You can send USDC from Arc to your own wallets on the supported networks, or to approved providers, through Circle Gateway. You can also bring it back to Arc.</li>
        <li>Circle charges a fee for each transfer, shown before you confirm. We also charge a small transfer fee (currently 0.10 USDC), shown before you confirm and taken from your Arc wallet only when the transfer completes. It covers the network fees we pay for you.</li>
        <li>Transfers can take up to about 20 minutes. Limits apply per transfer and per day, and you can have one transfer in progress at a time.</li>
        <li>We may refuse or pause transfers, for example when Circle&apos;s fee is unusually high or for security reasons.</li>
        <li>You can also send USDC, EURC or cirBTC from your wallet to any wallet address on Arc. You confirm each send with a code we email to you. Never share that code with anyone.</li>
        <li>Sends on a blockchain are final and cannot be reversed. You are responsible for the address you enter and for checking that it can receive the token on Arc. Funds sent to a wrong address, or to an exchange or wallet that does not support Arc, are lost and we cannot recover them.</li>
        <li>Limits apply per send and per day. We may refuse, delay or pause a send for security reasons or where the law requires it.</li>
      </ul>

      <h2>8. Swaps</h2>
      <ul>
        <li>Swaps between USDC, EURC and cirBTC on Arc use third party liquidity. Prices are set by the market, not by us, and some pairs may have no price at times.</li>
        <li>Our swap fee (currently 0.5%) is included in the amount shown. Before you confirm, we show the minimum you will receive. If the price moves below it, the swap is cancelled and nothing is taken.</li>
      </ul>

      <h2>9. Fees</h2>
      <p>
        Every fee is shown before you confirm: the service fee in each airtime or data price, Circle&apos;s fee and our
        transfer fee for transfers, and the swap fee. You do not pay network (gas) fees for your Arc wallet; we cover them. We may change our fees, and
        any change applies only to purchases made after it.
      </p>

      <h2>10. Things you must not do</h2>
      <ul>
        <li>Use dataonchain for fraud, money laundering, terrorist financing, sanctions evasion or any other unlawful purpose.</li>
        <li>Use stolen funds, or someone else&apos;s account or details without permission.</li>
        <li>Try to break, overload, copy or get around the security of the service.</li>
        <li>Abuse refunds, limits or promotions.</li>
      </ul>
      <p>We may ask you to verify your identity, and we may report suspicious activity to the authorities where the law requires it.</p>

      <h2>11. Suspension and closing accounts</h2>
      <p>
        We may suspend or close an account that breaks these terms, puts other users or the service at risk, or where the
        law requires it. A suspended account cannot start new purchases, transfers or swaps, but orders already in progress
        are completed and refunds are still sent. You can ask us to close your account at any time on WhatsApp. Any balance
        in your wallets must be moved out first.
      </p>

      <h2>12. Availability and changes</h2>
      <p>
        We work to keep dataonchain available, but we do not promise it will always be. We may pause parts of the service
        for maintenance or safety, and we may add, change or remove features. If we make a change that affects you
        significantly, we will tell you on the website.
      </p>

      <h2>13. Services we rely on</h2>
      <p>
        dataonchain depends on services we do not control, including the Arc blockchain, Circle (wallets, transfers and
        swaps), our airtime and data provider, the mobile networks, and our hosting and email providers. We are not
        responsible for their failures, but when one of them affects your order we will do what we reasonably can to help,
        including refunds where our Refund Policy applies.
      </p>

      <h2>14. Risks you should know</h2>
      <ul>
        <li>Stablecoins aim to keep a steady value but are not guaranteed. cirBTC and other tokens can change in value quickly.</li>
        <li>Blockchains and smart contracts can have faults, delays or outages.</li>
        <li>Laws about digital assets can change and may affect what we can offer.</li>
      </ul>

      <h2>15. Our responsibility to you</h2>
      <p>
        Nothing in these terms limits rights you have under Nigerian consumer protection law that cannot be limited. Apart
        from that, and as far as the law allows, we are not responsible for indirect or unforeseeable losses, and our total
        responsibility for any one claim is limited to the amount of the transaction it relates to.
      </p>

      <h2>16. Changes to these terms</h2>
      <p>
        We may update these terms. The date at the top shows the latest version. If a change is significant, we will tell
        you on the website before it applies. Continuing to use dataonchain after that means you accept the new terms.
      </p>

      <h2>17. Law and disputes</h2>
      <p>
        These terms are governed by the laws of the Federal Republic of Nigeria. If something goes wrong, please contact us
        first on WhatsApp so we can try to fix it. If we cannot agree, the dispute will be settled by the courts of Nigeria.
      </p>
    </LegalPage>
  );
}
