import path from 'path'
import { defineConfig } from 'vite'

const defaultWD = process.cwd()

export default defineConfig({
  root: path.resolve(defaultWD, 'web'),
  publicDir: path.resolve(defaultWD, 'fonts'),
  base: './'
})
