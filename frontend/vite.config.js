import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      // API 代理（本地開發用）
      '/api/db': {
        target: 'https://api-v2.yourspce.org',
        changeOrigin: true,
        secure: true
      },
      '/tools': {
        target: 'https://api-v2.yourspce.org',
        changeOrigin: true,
        secure: true
      },
      '/ai/': {
        target: 'https://api-v2.yourspce.org',
        changeOrigin: true,
        secure: true
      }
    }
  }
})
