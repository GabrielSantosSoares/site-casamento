import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Gabriel & Alanna | 03.10.2026",
  description:
    "Convite de casamento de Gabriel e Alanna — confirmação de presença, presentes e informações para o grande dia.",
  icons: {
    icon: "/monograma-ga.png",
    shortcut: "/monograma-ga.png",
    apple: "/monograma-ga.png",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}
