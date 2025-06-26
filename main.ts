import fs from 'fs'
import path from 'path'

const wasmPath = path.join(__dirname, 'zig-out', 'ttf.wasm')
const ttfPath = path.join(__dirname, 'fonts', 'sub5.ttf')

interface WASMInstance {
  memory: WebAssembly.Memory
  parse_ttf_font: (ptr: number, len: number) => number | null
  destroy_parser: (parser_ptr: number) => void
  get_num_tables: (parser_ptr: number) => number
  get_table_tag: (parser_ptr: number, index: number) => number
  has_head_table: (parser_ptr: number) => boolean
  get_head_info: (parser_ptr: number, info_ptr: number) => boolean
  has_maxp_table: (parser_ptr: number) => boolean
  get_maxp_info: (parser_ptr: number, info_ptr: number) => boolean
  has_hhea_table: (parser_ptr: number) => boolean
  get_hhea_info: (parser_ptr: number, info_ptr: number) => boolean
  get_mac_style_info: (parser_ptr: number, style_ptr: number) => boolean
  allocate_memory: (size: number) => number | null
  free_memory: (ptr: number, size: number) => void
}

interface HeadInfo {
  majorVersion: number
  minorVersion: number
  unitsPerEm: number
  flags: number
  magicNumber: number
}

interface MaxpInfo {
  version: number
  numGlyphs: number
  isTTF: boolean
  isCFF: boolean
}

interface HheaInfo {
  ascender: number
  descender: number
  lineGap: number
  advanceWidthMax: number
  numberOfHmetrics: number
}

interface MacStyleInfo {
  isBold: boolean
  isItalic: boolean
  hasAnyStyle: boolean
  rawValue: number
}

class TTFParser {
  private instance: WASMInstance
  private parserPtr: number | null = null

  constructor(instance: WASMInstance) {
    this.instance = instance
  }

  parse(fontData: Uint8Array): boolean {
    const ptr = this.instance.allocate_memory(fontData.length)
    if (ptr === null) return false

    const memory = new Uint8Array(this.instance.memory.buffer)
    memory.set(fontData, ptr)

    this.parserPtr = this.instance.parse_ttf_font(ptr, fontData.length)
    
    this.instance.free_memory(ptr, fontData.length)

    return this.parserPtr !== null
  }

  getNumTables(): number {
    if (!this.parserPtr) return 0
    return this.instance.get_num_tables(this.parserPtr)
  }

  getTableTag(index: number): string {
    if (!this.parserPtr) return ''
    const tag = this.instance.get_table_tag(this.parserPtr, index)
    return String.fromCharCode(
      (tag >>> 24) & 0xFF,
      (tag >>> 16) & 0xFF,
      (tag >>> 8) & 0xFF,
      tag & 0xFF
    )
  }

  hasHeadTable(): boolean {
    if (!this.parserPtr) return false
    return this.instance.has_head_table(this.parserPtr)
  }

  getHeadInfo(): HeadInfo | null {
    if (!this.parserPtr || !this.hasHeadTable()) return null

    const infoPtr = this.instance.allocate_memory(5 * 4) 
    if (infoPtr === null) return null

    const success = this.instance.get_head_info(this.parserPtr, infoPtr)
    if (!success) {
      this.instance.free_memory(infoPtr, 5 * 4)
      return null
    }

    const memory = new Uint32Array(this.instance.memory.buffer, infoPtr, 5)
    const result: HeadInfo = {
      majorVersion: memory[0],
      minorVersion: memory[1],
      unitsPerEm: memory[2],
      flags: memory[3],
      magicNumber: memory[4]
    }

    this.instance.free_memory(infoPtr, 5 * 4)
    return result
  }

  hasMaxpTable(): boolean {
    if (!this.parserPtr) return false
    return this.instance.has_maxp_table(this.parserPtr)
  }

  getMaxpInfo(): MaxpInfo | null {
    if (!this.parserPtr || !this.hasMaxpTable()) return null

    const infoPtr = this.instance.allocate_memory(4 * 4) 
    if (infoPtr === null) return null

    const success = this.instance.get_maxp_info(this.parserPtr, infoPtr)
    if (!success) {
      this.instance.free_memory(infoPtr, 4 * 4)
      return null
    }

    const memory = new Uint32Array(this.instance.memory.buffer, infoPtr, 4)
    const result: MaxpInfo = {
      version: memory[0],
      numGlyphs: memory[1],
      isTTF: memory[2] === 1,
      isCFF: memory[3] === 1
    }

    this.instance.free_memory(infoPtr, 4 * 4)
    return result
  }

  hasHheaTable(): boolean {
    if (!this.parserPtr) return false
    return this.instance.has_hhea_table(this.parserPtr)
  }

  getHheaInfo(): HheaInfo | null {
    if (!this.parserPtr || !this.hasHheaTable()) return null

    const infoPtr = this.instance.allocate_memory(5 * 4) 
    if (infoPtr === null) return null

    const success = this.instance.get_hhea_info(this.parserPtr, infoPtr)
    if (!success) {
      this.instance.free_memory(infoPtr, 5 * 4)
      return null
    }

    const memory = new Int32Array(this.instance.memory.buffer, infoPtr, 5)
    const result: HheaInfo = {
      ascender: memory[0],
      descender: memory[1],
      lineGap: memory[2],
      advanceWidthMax: memory[3],
      numberOfHmetrics: memory[4]
    }

    this.instance.free_memory(infoPtr, 5 * 4)
    return result
  }

  getMacStyleInfo(): MacStyleInfo | null {
    if (!this.parserPtr || !this.hasHeadTable()) return null

    const stylePtr = this.instance.allocate_memory(4 * 4) 
    if (stylePtr === null) return null

    const success = this.instance.get_mac_style_info(this.parserPtr, stylePtr)
    if (!success) {
      this.instance.free_memory(stylePtr, 4 * 4)
      return null
    }

    const memory = new Uint32Array(this.instance.memory.buffer, stylePtr, 4)
    const result: MacStyleInfo = {
      isBold: memory[0] === 1,
      isItalic: memory[1] === 1,
      hasAnyStyle: memory[2] === 1,
      rawValue: memory[3]
    }

    this.instance.free_memory(stylePtr, 4 * 4)
    return result
  }

  getAllTables(): string[] {
    const numTables = this.getNumTables()
    const tables: string[] = []
    
    for (let i = 0; i < numTables; i++) {
      tables.push(this.getTableTag(i))
    }
    
    return tables
  }

  destroy() {
    if (this.parserPtr) {
      this.instance.destroy_parser(this.parserPtr)
      this.parserPtr = null
    }
  }
}

function loadWASM(b64: string): WASMInstance {
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
  const compiledWASM = new WebAssembly.Module(bytes)
  const instance = new WebAssembly.Instance(compiledWASM, {}).exports as unknown as WASMInstance
  return instance
}

function main() {
  if (!fs.existsSync(wasmPath)) {
    throw new Error(`WASM file not found at ${wasmPath}`)
  }

  if (!fs.existsSync(ttfPath)) {
    throw new Error(`TTF file not found at ${ttfPath}`)
  }

  const wasmBuffer = fs.readFileSync(wasmPath, 'base64')
  const instance = loadWASM(wasmBuffer)

  if (!instance) {
    throw new Error('Failed to load WASM instance')
  }

  const fontData = new Uint8Array(fs.readFileSync(ttfPath))
  const parser = new TTFParser(instance)

  console.log('Parsing TTF font...')
  
  if (!parser.parse(fontData)) {
    console.error('Failed to parse TTF font')
    return
  }

  console.log('✅ Font parsed successfully!')
  
  console.log(`📊 Number of tables: ${parser.getNumTables()}`)
  console.log(`📋 Tables: ${parser.getAllTables().join(', ')}`)

  if (parser.hasHeadTable()) {
    const headInfo = parser.getHeadInfo()
    if (headInfo) {
      console.log('\n🗂️ Head Table Info:')
      console.log(`  Version: ${headInfo.majorVersion}.${headInfo.minorVersion}`)
      console.log(`  Units per EM: ${headInfo.unitsPerEm}`)
      console.log(`  Flags: 0x${headInfo.flags.toString(16)}`)
      console.log(`  Magic Number: 0x${headInfo.magicNumber.toString(16)}`)
    }
  }

  if (parser.hasMaxpTable()) {
    const maxpInfo = parser.getMaxpInfo()
    if (maxpInfo) {
      console.log('\n📏 Maxp Table Info:')
      console.log(`  Version: 0x${maxpInfo.version.toString(16)}`)
      console.log(`  Number of glyphs: ${maxpInfo.numGlyphs}`)
      console.log(`  Is TTF: ${maxpInfo.isTTF}`)
      console.log(`  Is CFF: ${maxpInfo.isCFF}`)
    }
  }

  if (parser.hasHheaTable()) {
    const hheaInfo = parser.getHheaInfo()
    if (hheaInfo) {
      console.log('\n📐 Hhea Table Info:')
      console.log(`  Ascender: ${hheaInfo.ascender}`)
      console.log(`  Descender: ${hheaInfo.descender}`)
      console.log(`  Line Gap: ${hheaInfo.lineGap}`)
      console.log(`  Max Advance Width: ${hheaInfo.advanceWidthMax}`)
      console.log(`  Number of H Metrics: ${hheaInfo.numberOfHmetrics}`)
    }
  }

  const macStyleInfo = parser.getMacStyleInfo()
  if (macStyleInfo) {
    console.log('\n🎨 Mac Style Info:')
    console.log(`  Bold: ${macStyleInfo.isBold}`)
    console.log(`  Italic: ${macStyleInfo.isItalic}`)
    console.log(`  Has any style: ${macStyleInfo.hasAnyStyle}`)
    console.log(`  Raw value: 0x${macStyleInfo.rawValue.toString(16)}`)
  }

  parser.destroy()
  console.log('\n✨ Cleanup completed!')
}

main()