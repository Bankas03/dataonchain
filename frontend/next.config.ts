import type { NextConfig } from "next";

// Every /api/... request to the website is passed through to the backend.
// The browser only talks to the website, so login cookies stay first party.
const API_URL = (process.env.API_URL ?? "http://localhost:4000").replace(/\/$/, "");

const nextConfig: NextConfig = {
  async rewrites() {
    return [{ source: "/api/:path*", destination: `${API_URL}/api/:path*` }];
  },
};

export default nextConfig;
