const withNextra = require('nextra')({
  theme: 'nextra-theme-docs',
  themeConfig: './theme.config.tsx',
})

// A GitHub Pages project site is served from https://<user>.github.io/<repo>/,
// so the export needs to know it lives under /konet — every asset URL and every
// next/link href is built from this. The deploy workflow passes the value from
// actions/configure-pages; locally it stays empty so `bun run dev` serves at /.
// A custom domain reports "/" or "", both of which mean "no prefix" — Next
// rejects a basePath of "/", hence the normalising.
const raw = process.env.NEXT_PUBLIC_BASE_PATH || ''
const basePath = raw === '/' ? '' : raw.replace(/\/$/, '')

module.exports = withNextra({
  output: 'export',
  basePath,
  images: {
    unoptimized: true,
  },
})
