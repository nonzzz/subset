export interface WASMInstance {
  memory: WebAssembly.Memory

  allocate_memory: (size: number) => number | null
  free_memory: (ptr: number, size: number) => void

  load_font_from_buffer: (ptr: number, len: number) => number | null
  load_font_from_file: (path_ptr: number, path_len: number) => number | null
  destroy_font_reader: (handle: number) => void

  create_subset_from_reader: (reader_handle: number) => number | null
  destroy_subset: (handle: number) => void

  get_font_metrics: (reader_handle: number, metrics_ptr: number) => number
  get_num_glyphs: (reader_handle: number) => number
  is_monospace: (reader_handle: number) => boolean
  get_glyph_id_for_codepoint: (reader_handle: number, codepoint: number) => number
  get_glyph_info: (reader_handle: number, glyph_id: number, info_ptr: number) => number

  get_font_name_length: (reader_handle: number, name_id: number) => number
  get_font_name: (reader_handle: number, name_id: number, buffer_ptr: number, buffer_len: number) => number
  get_glyph_name_length: (reader_handle: number, glyph_id: number) => number
  get_glyph_name: (reader_handle: number, glyph_id: number, buffer_ptr: number, buffer_len: number) => number

  add_text_to_subset: (subset_handle: number, text_ptr: number, text_len: number) => number
  add_character_to_subset: (subset_handle: number, codepoint: number) => number
  get_selected_glyphs_count: (subset_handle: number) => number
  get_selected_glyphs: (subset_handle: number, buffer_ptr: number, buffer_len: number) => number
  has_glyph_in_subset: (subset_handle: number, glyph_id: number) => boolean
  clear_subset_selection: (subset_handle: number) => void
  generate_subset_font: (subset_handle: number, output_ptr: number, output_len: number) => number

  create_subset_from_text: (
    font_ptr: number,
    font_len: number,
    text_ptr: number,
    text_len: number,
    output_ptr: number,
    output_len: number
  ) => number
  save_subset_to_file: (subset_handle: number, path_ptr: number, path_len: number) => number

  convert_ttf_to_woff: (font_ptr: number, font_len: number, output_ptr: number, output_len: number) => number
  convert_ttf_to_woff_from_reader: (reader_handle: number, output_ptr: number, output_len: number) => number

  get_error_message_length: (error_code: number) => number
  get_error_message: (error_code: number, buffer_ptr: number, buffer_len: number) => number
}

export interface WASMZigEnv extends WebAssembly.ModuleImports {
  host_read_file: (pathPtr: number, pathLen: number, outPtrPtr: number, outLenPtr: number) => boolean
  host_write_file: (pathPtr: number, pathLen: number, dataPtr: number, dataLen: number) => boolean
  host_head_modified_time: (outTimestampPtr: number) => boolean
  host_compress_data: (inputPtr: number, inputLen: number, outputPtrPtr: number, outputLenPtr: number) => boolean
}

const MAC_EPOCH_OFFSET = 2082844800 // Offset from Unix epoch to Mac epoch

export const ERR_CODE = {
  SUCCESS: 0,
  INVALID_POINTER: 1,
  ALLOCATION_FAILED: 2,
  PARSE_FAILED: 3,
  INVALID_UTF8: 4,
  MISSING_TABLE: 5,
  OUT_OF_BOUNDS: 6,
  COMPRESSION_FAILED: 7
} as const

export interface FontMetrics {
  ascender: number
  descender: number
  lineGap: number
  advanceWidthMax: number
  unitsPerEm: number
  xMin: number
  yMin: number
  xMax: number
  yMax: number
}

export interface GlyphInfo {
  glyphId: number
  codepoint: number
  advanceWidth: number
  leftSideBearing: number
  hasOutline: boolean
}

const IS_NODE_PLATFORM = typeof process !== 'undefined' && process.versions?.node

let FS_WRAP: Promise<typeof import('fs')> | null = null
let fs: typeof import('fs') | null = null

let ZLIB_WRAP: Promise<typeof import('zlib')> | null = null
let zlib: typeof import('zlib') | null = null

if (IS_NODE_PLATFORM) {
  try {
    FS_WRAP = import('fs').then((fsModule) => fsModule.default || fsModule)
    ZLIB_WRAP = import('zlib').then((zlibModule) => zlibModule.default || zlibModule)
  } catch {
  }
}

const decoder = new TextDecoder()

const encoder = new TextEncoder()

export class FontSubset {
  private instance: WASMInstance
  private readerHandle: number | null = null
  private subsetHandle: number | null = null

  constructor(instance: WASMInstance) {
    this.instance = instance
  }

  static async convertTtfToWoff(instance: WASMInstance, fontData: Uint8Array) {
    if (!zlib && IS_NODE_PLATFORM && ZLIB_WRAP) {
      zlib = await ZLIB_WRAP
    }
    const fontPtr = instance.allocate_memory(fontData.length)
    if (fontPtr === null) { return null }

    const outputPtrPtr = instance.allocate_memory(4)
    const outputLenPtr = instance.allocate_memory(4)

    if (outputPtrPtr === null || outputLenPtr === null) {
      instance.free_memory(fontPtr, fontData.length)
      if (outputPtrPtr) { instance.free_memory(outputPtrPtr, 4) }
      if (outputLenPtr) { instance.free_memory(outputLenPtr, 4) }
      return null
    }

    try {
      const memory = new Uint8Array(instance.memory.buffer)
      memory.set(fontData, fontPtr)

      const errorCode = instance.convert_ttf_to_woff(fontPtr, fontData.length, outputPtrPtr, outputLenPtr)

      if (errorCode !== ERR_CODE.SUCCESS) {
        return null
      }

      const outputPtr = new Uint32Array(instance.memory.buffer, outputPtrPtr, 1)[0]
      const outputLen = new Uint32Array(instance.memory.buffer, outputLenPtr, 1)[0]

      if (outputLen === 0) { return new Uint8Array(0) }

      const result = new Uint8Array(instance.memory.buffer, outputPtr, outputLen)
      const copy = new Uint8Array(result)

      instance.free_memory(outputPtr, outputLen)

      return copy
    } finally {
      instance.free_memory(fontPtr, fontData.length)
      instance.free_memory(outputPtrPtr, 4)
      instance.free_memory(outputLenPtr, 4)
    }
  }

  static createSubsetFromText(instance: WASMInstance, fontData: Uint8Array, text: string): Uint8Array | null {
    const fontPtr = instance.allocate_memory(fontData.length)
    if (fontPtr === null) { return null }

    const textData = encoder.encode(text)
    const textPtr = instance.allocate_memory(textData.length)
    if (textPtr === null) {
      instance.free_memory(fontPtr, fontData.length)
      return null
    }

    const outputPtrPtr = instance.allocate_memory(4)
    const outputLenPtr = instance.allocate_memory(4)

    if (outputPtrPtr === null || outputLenPtr === null) {
      instance.free_memory(fontPtr, fontData.length)
      instance.free_memory(textPtr, textData.length)
      if (outputPtrPtr) { instance.free_memory(outputPtrPtr, 4) }
      if (outputLenPtr) { instance.free_memory(outputLenPtr, 4) }
      return null
    }

    try {
      const memory = new Uint8Array(instance.memory.buffer)
      memory.set(fontData, fontPtr)
      memory.set(textData, textPtr)

      const errorCode = instance.create_subset_from_text(
        fontPtr,
        fontData.length,
        textPtr,
        textData.length,
        outputPtrPtr,
        outputLenPtr
      )

      if (errorCode !== ERR_CODE.SUCCESS) {
        return null
      }

      const outputPtr = new Uint32Array(instance.memory.buffer, outputPtrPtr, 1)[0]
      const outputLen = new Uint32Array(instance.memory.buffer, outputLenPtr, 1)[0]

      if (outputLen === 0) { return new Uint8Array(0) }

      const result = new Uint8Array(instance.memory.buffer, outputPtr, outputLen)
      const copy = new Uint8Array(result)

      instance.free_memory(outputPtr, outputLen)

      return copy
    } finally {
      instance.free_memory(fontPtr, fontData.length)
      instance.free_memory(textPtr, textData.length)
      instance.free_memory(outputPtrPtr, 4)
      instance.free_memory(outputLenPtr, 4)
    }
  }

  loadFont(fontData: Uint8Array): boolean {
    const ptr = this.instance.allocate_memory(fontData.length)
    if (ptr === null) { return false }

    const memory = new Uint8Array(this.instance.memory.buffer)
    memory.set(fontData, ptr)

    this.readerHandle = this.instance.load_font_from_buffer(ptr, fontData.length)

    this.instance.free_memory(ptr, fontData.length)

    return this.readerHandle !== null
  }

  async loadFile(path: string): Promise<boolean> {
    if (!fs && IS_NODE_PLATFORM && FS_WRAP) {
      fs = await FS_WRAP
    }
    const pathData = encoder.encode(path)
    const pathPtr = this.instance.allocate_memory(pathData.length)
    if (pathPtr === null) { return false }
    const memory = new Uint8Array(this.instance.memory.buffer)
    memory.set(pathData, pathPtr)
    this.readerHandle = this.instance.load_font_from_file(pathPtr, pathData.length)
    this.instance.free_memory(pathPtr, pathData.length)
    return this.readerHandle !== null
  }

  createSubset(): boolean {
    if (!this.readerHandle) { return false }

    this.subsetHandle = this.instance.create_subset_from_reader(this.readerHandle)
    return this.subsetHandle !== null
  }

  getFontMetrics(): FontMetrics | null {
    if (!this.readerHandle) { return null }

    const metricsPtr = this.instance.allocate_memory(9 * 4)
    if (metricsPtr === null) { return null }

    const errorCode = this.instance.get_font_metrics(this.readerHandle, metricsPtr)
    if (errorCode !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(metricsPtr, 9 * 4)
      return null
    }

    const memory = new Int32Array(this.instance.memory.buffer, metricsPtr, 9)
    const result: FontMetrics = {
      ascender: memory[0],
      descender: memory[1],
      lineGap: memory[2],
      advanceWidthMax: memory[3],
      unitsPerEm: memory[4],
      xMin: memory[5],
      yMin: memory[6],
      xMax: memory[7],
      yMax: memory[8]
    }

    this.instance.free_memory(metricsPtr, 9 * 4)
    return result
  }

  getNumGlyphs(): number {
    if (!this.readerHandle) { return 0 }
    return this.instance.get_num_glyphs(this.readerHandle)
  }

  isMonospace(): boolean {
    if (!this.readerHandle) { return false }
    return this.instance.is_monospace(this.readerHandle)
  }

  getGlyphIdForCodepoint(codepoint: number): number {
    if (!this.readerHandle) { return 0 }
    return this.instance.get_glyph_id_for_codepoint(this.readerHandle, codepoint)
  }

  getGlyphInfo(glyphId: number): GlyphInfo | null {
    if (!this.readerHandle) { return null }

    const infoPtr = this.instance.allocate_memory(5 * 4)
    if (infoPtr === null) { return null }

    const errorCode = this.instance.get_glyph_info(this.readerHandle, glyphId, infoPtr)
    if (errorCode !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(infoPtr, 5 * 4)
      return null
    }

    const memory = new Uint32Array(this.instance.memory.buffer, infoPtr, 5)
    const result: GlyphInfo = {
      glyphId: memory[0],
      codepoint: memory[1],
      advanceWidth: memory[2],
      leftSideBearing: new Int32Array(this.instance.memory.buffer, infoPtr + 12, 1)[0],
      hasOutline: memory[4] === 1
    }

    this.instance.free_memory(infoPtr, 5 * 4)
    return result
  }

  getFontName(nameId: number): string | null {
    if (!this.readerHandle) { return null }

    const length = this.instance.get_font_name_length(this.readerHandle, nameId)
    if (length === 0) { return null }

    const bufferPtr = this.instance.allocate_memory(length)
    if (bufferPtr === null) { return null }

    const errorCode = this.instance.get_font_name(this.readerHandle, nameId, bufferPtr, length)
    if (errorCode !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(bufferPtr, length)
      return null
    }

    const memory = new Uint8Array(this.instance.memory.buffer, bufferPtr, length)
    const result = new TextDecoder().decode(memory)

    this.instance.free_memory(bufferPtr, length)
    return result
  }

  getGlyphName(glyphId: number): string | null {
    if (!this.readerHandle) { return null }

    const length = this.instance.get_glyph_name_length(this.readerHandle, glyphId)
    if (length === 0) { return null }

    const bufferPtr = this.instance.allocate_memory(length)
    if (bufferPtr === null) { return null }

    const errorCode = this.instance.get_glyph_name(this.readerHandle, glyphId, bufferPtr, length)
    if (errorCode !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(bufferPtr, length)
      return null
    }

    const memory = new Uint8Array(this.instance.memory.buffer, bufferPtr, length)
    const result = new TextDecoder().decode(memory)

    this.instance.free_memory(bufferPtr, length)
    return result
  }

  addTextToSubset(text: string): boolean {
    if (!this.subsetHandle) { return false }

    const textData = new TextEncoder().encode(text)
    const textPtr = this.instance.allocate_memory(textData.length)
    if (textPtr === null) { return false }

    const memory = new Uint8Array(this.instance.memory.buffer)
    memory.set(textData, textPtr)

    const errorCode = this.instance.add_text_to_subset(this.subsetHandle, textPtr, textData.length)

    this.instance.free_memory(textPtr, textData.length)

    return errorCode === ERR_CODE.SUCCESS
  }

  addCharacterToSubset(codepoint: number): boolean {
    if (!this.subsetHandle) { return false }

    const errorCode = this.instance.add_character_to_subset(this.subsetHandle, codepoint)
    return errorCode === ERR_CODE.SUCCESS
  }

  getSelectedGlyphs(): number[] {
    if (!this.subsetHandle) { return [] }

    const count = this.instance.get_selected_glyphs_count(this.subsetHandle)
    if (count === 0) { return [] }

    const bufferPtr = this.instance.allocate_memory(count * 2)
    if (bufferPtr === null) { return [] }

    const errorCode = this.instance.get_selected_glyphs(this.subsetHandle, bufferPtr, count)
    if (errorCode !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(bufferPtr, count * 2)
      return []
    }

    const memory = new Uint16Array(this.instance.memory.buffer, bufferPtr, count)
    const result = Array.from(memory)

    this.instance.free_memory(bufferPtr, count * 2)
    return result
  }

  hasGlyphInSubset(glyphId: number): boolean {
    if (!this.subsetHandle) { return false }
    return this.instance.has_glyph_in_subset(this.subsetHandle, glyphId)
  }

  clearSubsetSelection(): void {
    if (this.subsetHandle) {
      this.instance.clear_subset_selection(this.subsetHandle)
    }
  }

  generateSubsetFont(): Uint8Array | null {
    if (!this.subsetHandle) { return null }

    const outputPtrPtr = this.instance.allocate_memory(4)
    const outputLenPtr = this.instance.allocate_memory(4)

    if (outputPtrPtr === null || outputLenPtr === null) {
      if (outputPtrPtr) { this.instance.free_memory(outputPtrPtr, 4) }
      if (outputLenPtr) { this.instance.free_memory(outputLenPtr, 4) }
      return null
    }

    const errorCode = this.instance.generate_subset_font(this.subsetHandle, outputPtrPtr, outputLenPtr)
    if (errorCode !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(outputPtrPtr, 4)
      this.instance.free_memory(outputLenPtr, 4)
      return null
    }

    const outputPtr = new Uint32Array(this.instance.memory.buffer, outputPtrPtr, 1)[0]
    const outputLen = new Uint32Array(this.instance.memory.buffer, outputLenPtr, 1)[0]

    this.instance.free_memory(outputPtrPtr, 4)
    this.instance.free_memory(outputLenPtr, 4)

    if (outputLen === 0) { return new Uint8Array(0) }

    const result = new Uint8Array(this.instance.memory.buffer, outputPtr, outputLen)
    const copy = new Uint8Array(result)

    this.instance.free_memory(outputPtr, outputLen)
    return copy
  }

  getErrorMessage(errorCode: typeof ERR_CODE[keyof typeof ERR_CODE]): string {
    const length = this.instance.get_error_message_length(errorCode)
    if (length === 0) { return 'Unknown error' }

    const bufferPtr = this.instance.allocate_memory(length)
    if (bufferPtr === null) { return 'Memory allocation failed' }

    const result = this.instance.get_error_message(errorCode, bufferPtr, length)
    if (result !== ERR_CODE.SUCCESS) {
      this.instance.free_memory(bufferPtr, length)
      return 'Failed to get error message'
    }

    const memory = new Uint8Array(this.instance.memory.buffer, bufferPtr, length)
    const message = new TextDecoder().decode(memory)

    this.instance.free_memory(bufferPtr, length)
    return message
  }

  destroy(): void {
    if (this.subsetHandle) {
      this.instance.destroy_subset(this.subsetHandle)
      this.subsetHandle = null
    }
    if (this.readerHandle) {
      this.instance.destroy_font_reader(this.readerHandle)
      this.readerHandle = null
    }
  }
}

let WASM_INSTANCE: WASMInstance | null = null

export function createSubsetEngine(binary: Uint8Array): FontSubset {
  if (WASM_INSTANCE) {
    return new FontSubset(WASM_INSTANCE)
  }

  const compiledWASM = new WebAssembly.Module(binary)
  const env = <WASMZigEnv> {
    host_read_file: (pathPtr: number, pathLen: number, outPtrPtr: number, outLenPtr: number) => {
      try {
        if (!WASM_INSTANCE) { return 0 }
        const memory = new Uint8Array(WASM_INSTANCE.memory.buffer)
        const pathBytes = memory.slice(pathPtr, pathPtr + pathLen)
        const path = decoder.decode(pathBytes)

        if (IS_NODE_PLATFORM && fs) {
          const buffer = fs.readFileSync(path)
          const fileData = new Uint8Array(buffer)

          const dataPtr = WASM_INSTANCE.allocate_memory(fileData.length)
          if (dataPtr === null) {
            return false
          }

          const wasmMemory = new Uint8Array(WASM_INSTANCE.memory.buffer)
          wasmMemory.set(fileData, dataPtr)

          const outPtrView = new Uint32Array(WASM_INSTANCE.memory.buffer, outPtrPtr, 1)
          const outLenView = new Uint32Array(WASM_INSTANCE.memory.buffer, outLenPtr, 1)

          outPtrView[0] = dataPtr
          outLenView[0] = fileData.length

          return true
        }
        return false
      } catch {
        return false
      }
    },
    host_write_file: (pathPtr: number, pathLen: number, dataPtr: number, dataLen: number) => {
      try {
        if (!WASM_INSTANCE) { return false }
        const memory = new Uint8Array(WASM_INSTANCE.memory.buffer)
        const pathBytes = memory.slice(pathPtr, pathPtr + pathLen)
        const path = decoder.decode(pathBytes)
        const data = memory.slice(dataPtr, dataPtr + dataLen)
        if (IS_NODE_PLATFORM && fs) {
          fs.writeFileSync(path, data)
          return true
        }
      } catch {
        return false
      }
    },
    host_head_modified_time: (outTimestampPtr: number) => {
      try {
        if (!WASM_INSTANCE) { return false }
        const currentUnixTime = Math.floor(Date.now() / 1000)
        const currentMacTime = currentUnixTime + MAC_EPOCH_OFFSET
        const timestampView = new BigUint64Array(WASM_INSTANCE.memory.buffer, outTimestampPtr, 1)
        timestampView[0] = BigInt(currentMacTime)
        return true
      } catch {
        return false
      }
    },
    host_compress_data(inputPtr, inputLen, outputPtrPtr, outputLenPtr) {
      try {
        if (!WASM_INSTANCE) { return false }
        if (IS_NODE_PLATFORM && zlib) {
          const memory = new Uint8Array(WASM_INSTANCE.memory.buffer)
          const inputData = memory.slice(inputPtr, inputPtr + inputLen)

          const compressedData = zlib.deflateSync(inputData)

          const outputPtr = WASM_INSTANCE.allocate_memory(compressedData.length)
          if (outputPtr === null) { return false }

          const outputMemory = new Uint8Array(WASM_INSTANCE.memory.buffer)
          outputMemory.set(compressedData, outputPtr)

          const outPtrView = new Uint32Array(WASM_INSTANCE.memory.buffer, outputPtrPtr, 1)
          const outLenView = new Uint32Array(WASM_INSTANCE.memory.buffer, outputLenPtr, 1)

          outPtrView[0] = outputPtr
          outLenView[0] = compressedData.length

          return true
        }
        return false
      } catch {
        return false
      }
    }
  }
  WASM_INSTANCE = new WebAssembly.Instance(compiledWASM, { env }).exports as unknown as WASMInstance

  return new FontSubset(WASM_INSTANCE)
}

export function createSubsetFromText(
  fontData: Uint8Array,
  text: string
): Uint8Array | null {
  if (!WASM_INSTANCE) { return null }
  return FontSubset.createSubsetFromText(WASM_INSTANCE, fontData, text)
}

export async function convertTtfToWoff(fontData: Uint8Array) {
  if (!WASM_INSTANCE) { return null }
  return FontSubset.convertTtfToWoff(WASM_INSTANCE, fontData)
}
