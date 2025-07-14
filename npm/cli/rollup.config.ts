import commonJS from '@rollup/plugin-commonjs'
import { nodeResolve } from '@rollup/plugin-node-resolve'
import { builtinModules } from 'module'
import { defineConfig } from 'rollup'
import { swc } from 'rollup-plugin-swc3'

export default defineConfig({
  input: ['./src/index.ts'],
  plugins: [nodeResolve(), commonJS(), swc()],
  external: ['ttf.zig', 'tinyglobby', ...builtinModules],
  output: {
    format: 'cjs',
    file: 'dist/index.js'
  }
})
