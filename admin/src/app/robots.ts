import type { MetadataRoute } from "next";

// Search engines: stay out
export default function robots(): MetadataRoute.Robots {
  return { rules: { userAgent: "*", disallow: "/" } };
}
