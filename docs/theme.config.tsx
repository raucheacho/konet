import { DocsThemeConfig } from 'nextra-theme-docs'

const config: DocsThemeConfig = {
  // The gradient lives in styles.css so it can differ per theme — the dark
  // ramp washes out on white.
  logo: <span className="konet-logo">Konet</span>,
  project: {
    link: 'https://github.com/raucheacho/konet',
  },
  docsRepositoryBase: 'https://github.com/raucheacho/konet/tree/main/docs',
  footer: {
    text: 'Konet Docs — MIT License',
  },
  useNextSeoProps() {
    return {
      titleTemplate: '%s – Konet',
    }
  },
  head: (
    <>
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <meta name="theme-color" content="#0a0a0f" />
      <link rel="preconnect" href="https://fonts.googleapis.com" />
      <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet" />
    </>
  ),
  primaryHue: 252,
  primarySaturation: 90,
  sidebar: {
    defaultMenuCollapseLevel: 1,
  },
  darkMode: true,
}

export default config
