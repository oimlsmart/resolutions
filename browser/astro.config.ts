import { defineConfig } from 'astro/config'
import sitemap from '@astrojs/sitemap'
import vue from '@astrojs/vue'
import browser from '@edoxen/browser/integration'
import tailwindcss from '@tailwindcss/vite'
import cfg from './edoxen.config'

export default defineConfig({
  site: cfg.site.url,
  base: cfg.site.basePath === '/' ? undefined : cfg.site.basePath,
  integrations: [
    browser({ config: cfg, injectRoutes: false }),
    sitemap(),
    vue(),
  ],
  vite: {
    plugins: [
      tailwindcss(),
    ],
    // The vendored site-shell's islands resolve vue from the site root.
    resolve: { dedupe: ['vue'] },
  },
})
