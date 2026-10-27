// Support is on WhatsApp. Links open a chat with an optional message already typed.
export const SUPPORT_WHATSAPP = "2348038526981";
export const SUPPORT_WHATSAPP_DISPLAY = "+234 803 852 6981";

export function whatsappUrl(message?: string): string {
  const base = `https://wa.me/${SUPPORT_WHATSAPP}`;
  return message ? `${base}?text=${encodeURIComponent(message)}` : base;
}
