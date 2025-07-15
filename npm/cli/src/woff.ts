import zlib from 'zlib'

function ulong(t: number): number {
  t >>>= 0
  return t
}

function longAlign(n: number): number {
  return (n + 3) & ~3
}

function calc_checksum(buf: Uint8Array): number {
  let sum = 0
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
  const nlongs = Math.floor(buf.length / 4)
  for (let i = 0; i < nlongs; ++i) {
    const t = dv.getUint32(i * 4, false)
    sum = ulong(sum + t)
  }
  return sum
}

function writeUint32BE(arr: Uint8Array, offset: number, value: number) {
  const dv = new DataView(arr.buffer, arr.byteOffset, arr.byteLength)
  dv.setUint32(offset, value, false)
}

function writeUint16BE(arr: Uint8Array, offset: number, value: number) {
  const dv = new DataView(arr.buffer, arr.byteOffset, arr.byteLength)
  dv.setUint16(offset, value, false)
}

function readUint32BE(arr: Uint8Array, offset: number): number {
  const dv = new DataView(arr.buffer, arr.byteOffset, arr.byteLength)
  return dv.getUint32(offset, false)
}

function readUint16BE(arr: Uint8Array, offset: number): number {
  const dv = new DataView(arr.buffer, arr.byteOffset, arr.byteLength)
  return dv.getUint16(offset, false)
}

const WOFF_OFFSET = {
  MAGIC: 0,
  FLAVOR: 4,
  SIZE: 8,
  NUM_TABLES: 12,
  RESERVED: 14,
  SFNT_SIZE: 16,
  VERSION_MAJ: 20,
  VERSION_MIN: 22,
  META_OFFSET: 24,
  META_LENGTH: 28,
  META_ORIG_LENGTH: 32,
  PRIV_OFFSET: 36,
  PRIV_LENGTH: 40
}

const WOFF_ENTRY_OFFSET = {
  TAG: 0,
  OFFSET: 4,
  COMPR_LENGTH: 8,
  LENGTH: 12,
  CHECKSUM: 16
}

const SFNT_OFFSET = {
  TAG: 0,
  CHECKSUM: 4,
  OFFSET: 8,
  LENGTH: 12
}

const SFNT_ENTRY_OFFSET = {
  FLAVOR: 0,
  VERSION_MAJ: 4,
  VERSION_MIN: 6,
  CHECKSUM_ADJUSTMENT: 8
}

const MAGIC = {
  WOFF: 0x774F4646,
  CHECKSUM_ADJUSTMENT: 0xB1B0AFBA
}

const SIZEOF = {
  WOFF_HEADER: 44,
  WOFF_ENTRY: 20,
  SFNT_HEADER: 12,
  SFNT_TABLE_ENTRY: 16
}

function woffAppendMetadata(src: Uint8Array, metadata: Uint8Array) {
  const zdata = zlib.deflateSync(metadata)
  const out = new Uint8Array(src.length + zdata.length)
  out.set(src)
  out.set(zdata, src.length)
  writeUint32BE(out, WOFF_OFFSET.SIZE, out.length)
  writeUint32BE(out, WOFF_OFFSET.META_OFFSET, src.length)
  writeUint32BE(out, WOFF_OFFSET.META_LENGTH, zdata.length)
  writeUint32BE(out, WOFF_OFFSET.META_ORIG_LENGTH, metadata.length)
  return out
}

export function ttf2woff(input: Uint8Array, options: { metadata?: Uint8Array } = {}): Uint8Array {
  const arr = input
  const version = { maj: 0, min: 1 }
  const numTables = readUint16BE(arr, 4)
  let flavor = 0x10000

  const woffHeader = new Uint8Array(SIZEOF.WOFF_HEADER)
  writeUint32BE(woffHeader, WOFF_OFFSET.MAGIC, MAGIC.WOFF)
  writeUint16BE(woffHeader, WOFF_OFFSET.NUM_TABLES, numTables)
  writeUint16BE(woffHeader, WOFF_OFFSET.RESERVED, 0)
  writeUint32BE(woffHeader, WOFF_OFFSET.SFNT_SIZE, 0)
  writeUint32BE(woffHeader, WOFF_OFFSET.META_OFFSET, 0)
  writeUint32BE(woffHeader, WOFF_OFFSET.META_LENGTH, 0)
  writeUint32BE(woffHeader, WOFF_OFFSET.META_ORIG_LENGTH, 0)
  writeUint32BE(woffHeader, WOFF_OFFSET.PRIV_OFFSET, 0)
  writeUint32BE(woffHeader, WOFF_OFFSET.PRIV_LENGTH, 0)

  type TableEntry = {
    Tag: Uint8Array,
    checkSum: number,
    Offset: number,
    Length: number
  }
  let entries: TableEntry[] = []

  for (let i = 0; i < numTables; ++i) {
    const base = SIZEOF.SFNT_HEADER + i * SIZEOF.SFNT_TABLE_ENTRY
    const data = arr.subarray(base, base + SIZEOF.SFNT_TABLE_ENTRY)
    entries.push({
      Tag: data.subarray(SFNT_OFFSET.TAG, SFNT_OFFSET.TAG + 4),
      checkSum: readUint32BE(data, SFNT_OFFSET.CHECKSUM),
      Offset: readUint32BE(data, SFNT_OFFSET.OFFSET),
      Length: readUint32BE(data, SFNT_OFFSET.LENGTH)
    })
  }
  entries = entries.sort((a, b) => {
    const aStr = String.fromCharCode(...a.Tag)
    const bStr = String.fromCharCode(...b.Tag)
    return aStr === bStr ? 0 : aStr < bStr ? -1 : 1
  })

  let offset = SIZEOF.WOFF_HEADER + numTables * SIZEOF.WOFF_ENTRY
  let woffSize = offset
  let sfntSize = SIZEOF.SFNT_HEADER + numTables * SIZEOF.SFNT_TABLE_ENTRY

  const tableBuf = new Uint8Array(numTables * SIZEOF.WOFF_ENTRY)

  for (let i = 0; i < numTables; ++i) {
    const tableEntry = entries[i]
    if (String.fromCharCode(...tableEntry.Tag) !== 'head') {
      const algntable = arr.subarray(tableEntry.Offset, tableEntry.Offset + longAlign(tableEntry.Length))
      if (calc_checksum(algntable) !== tableEntry.checkSum) {
        throw new Error('Checksum error in ' + String.fromCharCode(...tableEntry.Tag))
      }
    }
    writeUint32BE(tableBuf, i * SIZEOF.WOFF_ENTRY + WOFF_ENTRY_OFFSET.TAG, readUint32BE(tableEntry.Tag, 0))
    writeUint32BE(tableBuf, i * SIZEOF.WOFF_ENTRY + WOFF_ENTRY_OFFSET.LENGTH, tableEntry.Length)
    writeUint32BE(tableBuf, i * SIZEOF.WOFF_ENTRY + WOFF_ENTRY_OFFSET.CHECKSUM, tableEntry.checkSum)
    sfntSize += longAlign(tableEntry.Length)
  }

  let sfntOffset = SIZEOF.SFNT_HEADER + entries.length * SIZEOF.SFNT_TABLE_ENTRY
  let csum = calc_checksum(arr.subarray(0, SIZEOF.SFNT_HEADER))

  for (let i = 0; i < entries.length; ++i) {
    const tableEntry = entries[i]
    const b = new Uint8Array(SIZEOF.SFNT_TABLE_ENTRY)
    writeUint32BE(b, SFNT_OFFSET.TAG, readUint32BE(tableEntry.Tag, 0))
    writeUint32BE(b, SFNT_OFFSET.CHECKSUM, tableEntry.checkSum)
    writeUint32BE(b, SFNT_OFFSET.OFFSET, sfntOffset)
    writeUint32BE(b, SFNT_OFFSET.LENGTH, tableEntry.Length)
    sfntOffset += longAlign(tableEntry.Length)
    csum += calc_checksum(b)
    csum += tableEntry.checkSum
  }

  const checksumAdjustment = ulong(MAGIC.CHECKSUM_ADJUSTMENT - csum)

  const woffDataChains: Uint8Array[] = []

  for (let i = 0; i < entries.length; ++i) {
    const tableEntry = entries[i]
    const sfntData = arr.subarray(tableEntry.Offset, tableEntry.Offset + tableEntry.Length)
    const sfntDataCopy = new Uint8Array(sfntData)

    if (String.fromCharCode(...tableEntry.Tag) === 'head') {
      version.maj = readUint16BE(sfntDataCopy, SFNT_ENTRY_OFFSET.VERSION_MAJ)
      version.min = readUint16BE(sfntDataCopy, SFNT_ENTRY_OFFSET.VERSION_MIN)
      flavor = readUint32BE(sfntDataCopy, SFNT_ENTRY_OFFSET.FLAVOR)
      writeUint32BE(sfntDataCopy, SFNT_ENTRY_OFFSET.CHECKSUM_ADJUSTMENT, checksumAdjustment)
    }

    const res = zlib.deflateSync(sfntDataCopy)
    const compLength = Math.min(res.length, sfntDataCopy.length)
    const len = longAlign(compLength)
    const woffData = new Uint8Array(len)
    if (res.length >= sfntDataCopy.length) {
      woffData.set(sfntDataCopy)
    } else {
      woffData.set(res)
    }
    writeUint32BE(tableBuf, i * SIZEOF.WOFF_ENTRY + WOFF_ENTRY_OFFSET.OFFSET, offset)
    offset += woffData.length
    woffSize += woffData.length
    writeUint32BE(tableBuf, i * SIZEOF.WOFF_ENTRY + WOFF_ENTRY_OFFSET.COMPR_LENGTH, compLength)
    woffDataChains.push(woffData)
  }

  writeUint32BE(woffHeader, WOFF_OFFSET.SIZE, woffSize)
  writeUint32BE(woffHeader, WOFF_OFFSET.SFNT_SIZE, sfntSize)
  writeUint16BE(woffHeader, WOFF_OFFSET.VERSION_MAJ, version.maj)
  writeUint16BE(woffHeader, WOFF_OFFSET.VERSION_MIN, version.min)
  writeUint32BE(woffHeader, WOFF_OFFSET.FLAVOR, flavor)

  let out = new Uint8Array(woffSize)
  let pos = 0
  out.set(woffHeader, pos)
  pos += woffHeader.length
  out.set(tableBuf, pos)
  pos += tableBuf.length
  for (let i = 0; i < woffDataChains.length; i++) {
    out.set(woffDataChains[i], pos)
    pos += woffDataChains[i].length
  }

  if (options.metadata) {
    out = woffAppendMetadata(out, options.metadata)
  }

  return out
}
