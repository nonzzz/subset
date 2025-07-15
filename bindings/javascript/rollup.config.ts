import fs from 'fs'
import { builtinModules } from 'module'
import path from 'path'
import { defineConfig } from 'rollup'
import type { Plugin } from 'rollup'
import { dts } from 'rollup-plugin-dts'
import { swc } from 'rollup-plugin-swc3'

const defaultWD = process.cwd()

const external = [...builtinModules]

const WASM_BINARY_PATH = path.join(defaultWD, 'zig-out', 'ttf.wasm')

const WASM_INPUT_PATH = path.join(defaultWD, 'bindings/javascript/wasm.ts')

const NPM_OUTPUT_PATH = path.join(defaultWD, 'npm/ttf.zig', 'dist')

const WASM_BINARY_B64 = fs.readFileSync(WASM_BINARY_PATH, 'base64')

const WASM_INPUT_CODE = fs.readFileSync(WASM_INPUT_PATH, 'utf-8').replace(
  `export function createSubsetEngine`,
  'function createSubsetEngine'
)

const VIRTUAL_CODE = `
${WASM_INPUT_CODE}
const bytes = Uint8Array.from(atob('${WASM_BINARY_B64}'), c => c.charCodeAt(0));
export const ttf = createSubsetEngine(bytes);
`

function virtualWASM(): Plugin {
  return {
    name: 'virtual:wasm',
    resolveId(id) {
      if (id === 'virtual:wasm') {
        return 'index.ts'
      }
    },
    load(id) {
      if (id === 'index.ts') {
        return VIRTUAL_CODE
      }
    }
  }
}

export default defineConfig([
  {
    input: 'virtual:wasm',
    external,
    output: [
      {
        dir: NPM_OUTPUT_PATH,
        format: 'es',
        exports: 'named',
        entryFileNames: '[name].mjs',
        chunkFileNames: '[name]-[hash].mjs'
      },
      {
        dir: NPM_OUTPUT_PATH,
        format: 'cjs',
        exports: 'named',
        entryFileNames: '[name].js',
        chunkFileNames: '[name]-[hash].js'
      }
    ],
    plugins: [virtualWASM(), swc()]
  },
  {
    input: WASM_INPUT_PATH,
    external,
    output: [
      { dir: NPM_OUTPUT_PATH, format: 'esm', entryFileNames: 'index.d.mts' },
      { dir: NPM_OUTPUT_PATH, format: 'cjs', entryFileNames: 'index.d.ts' }
    ],
    plugins: [
      {
        name: 'virtual:wasm-dts',
        generateBundle(_, bundles) {
          for (const key in bundles) {
            const chunk = bundles[key]
            if (chunk.type === 'chunk') {
              const pos = chunk.code.indexOf('declare function createSubsetEngine(binary: Uint8Array): FontSubset;')
              chunk.code = chunk.code.slice(0, pos) +
                'export declare const ttf: FontSubset;\n' +
                chunk.code.slice(pos + 'declare function createSubsetEngine(binary: Uint8Array): FontSubset;'.length)
              chunk.code = chunk.code.replace('declare function createSubsetEngine(binary: Uint8Array): FontSubset;', '')
            }
          }
        }
      },
      dts({
        respectExternal: true,
        compilerOptions: {
          composite: true,
          preserveSymlinks: false
        }
      })
    ]
  }
])
