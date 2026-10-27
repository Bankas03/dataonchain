import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Refund Policy · dataonchain" };

export default function RefundPolicyPage() {
  return (
    <LegalPage
      title="Refund Policy"
      updated="27 October 2026"
      intro={
        <p>
          When you pay for something we cannot deliver, you get your money back automatically, without having to ask. This
          page explains when refunds happen, how long they take, and the few cases where a refund is not possible.
        </p>
      }
    >
      <h2>1. Automatic refunds</h2>
      <p>You are refunded in full, automatically, when:</p>
      <ul>
        <li>the mobile network or our provider cannot deliver the airtime or data you paid for;</li>
        <li>our provider confirms it never received or completed the purchase;</li>
        <li>an order that was under review is confirmed as not delivered.</li>
      </ul>
      <p>
        The full USDC amount you paid goes back to your dataonchain wallet on Arc, usually within a minute. The order page
        shows each step, and the refund transaction, which you can open in the Arc explorer.
      </p>

      <h2>2. Orders under review</h2>
      <p>
        Sometimes a network takes a long time to confirm a delivery. The order then shows Checking while we confirm with
        our provider. It always ends as either delivered or refunded. This can take longer than usual, occasionally up to a
        few days.
      </p>

      <h2>3. Payments that did not go through</h2>
      <p>
        If your payment fails, no USDC leaves your wallet, so there is nothing to refund. If a payment was interrupted
        (for example by a connection problem), we check it with Circle automatically: the order then either continues or
        is refunded.
      </p>

      <h2>4. When a refund is not possible</h2>
      <ul>
        <li><strong>Wrong but valid phone number:</strong> airtime or data delivered to a valid number cannot be taken back. Please check the number and network before you pay.</li>
        <li><strong>Delivered orders:</strong> once airtime or data is delivered, it cannot be cancelled or exchanged.</li>
        <li><strong>Problems after delivery</strong> (for example how a network uses or expires your data): please contact your mobile network.</li>
        <li><strong>Circle&apos;s transfer fees</strong> on transfers between networks are paid to Circle and are not refundable. Any unused part of the fee stays in your bridge balance and is used for your next transfer.</li>
        <li><strong>Swaps</strong> that completed at or above the minimum shown cannot be reversed. Swaps that would give less than that minimum are cancelled automatically, and nothing is taken.</li>
      </ul>

      <h2>5. Transfers between networks</h2>
      <p>
        If a transfer to another network fails before it completes, your USDC stays in your wallet or in your bridge
        balance, and is used for your next transfer. If you think a transfer went wrong, contact us with the transfer
        details from your Send to another network page.
      </p>

      <h2>6. How refunds are paid</h2>
      <p>
        Refunds are paid in the same token you paid with (USDC) to your dataonchain wallet on Arc. We do not pay refunds in
        cash, in naira or to a bank account.
      </p>

      <h2>7. If you think something is wrong</h2>
      <p>
        Message us on WhatsApp with your order reference (it starts with ARC and is shown on the order page). The Report a
        problem button on each order page fills it in for you. We will look into it and reply as soon as we can.
      </p>
    </LegalPage>
  );
}
