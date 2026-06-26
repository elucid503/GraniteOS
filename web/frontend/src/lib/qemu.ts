/** Emscripten Module shape used by QEMU Wasm. */
export interface QemuModule {

  arguments: string[]
  pty?: unknown

  mainScriptUrlOrBlob?: string

  preRun?: Array<() => void>
  locateFile?: (path: string, prefix: string) => string

  addRunDependency?: (id: string) => void
  removeRunDependency?: (id: string) => void

  FS_createPath?: (parent: string, path: string, canRead: boolean, canWrite: boolean) => void
  FS_createDataFile?: (parent: string, name: string | null, data: Uint8Array, canRead: boolean, canWrite: boolean, canOwn: boolean) => void

  PThread?: { terminateAllThreads: () => void }

  TTY?: {

    stream_ops: {

      poll: (stream: unknown, timeout: number) => number

    }

  }

}

declare global {

  interface Window {

    Module?: QemuModule

  }

}

// Single emulated core to reduce host CPU.
const QEMU_ARGS = [

  '-machine', 'virt',
  '-cpu', 'cortex-a57',
  '-smp', '1',
  '-m', '256M',
  '-display', 'none',
  '-nographic',
  '-accel', 'tcg,tb-size=500',
  '-nic', 'none',
  '-kernel', '/pack/kernel',
  '-drive', 'file=/pack/disk.img,format=raw,if=none,id=hd0',
  '-device', 'virtio-blk-device,drive=hd0',

] as const

async function fetchAsset(url: string, label: string): Promise<ArrayBuffer> {

  const res = await fetch(url)
  if (!res.ok) throw new Error(`${label}: ${res.status}`)

  return res.arrayBuffer()

}

function preloadAssets(module: QemuModule, kernel: ArrayBuffer, disk: ArrayBuffer) {

  const orig = module.preRun ?? []

  module.preRun = [...orig, () => {

    module.FS_createPath?.('/', 'pack', true, true)
    module.FS_createDataFile?.('/pack', 'kernel', new Uint8Array(kernel), true, true, true)
    module.FS_createDataFile?.('/pack', 'disk.img', new Uint8Array(disk), true, true, true)

  }]

}

function patchTtyPoll(module: QemuModule) {

  const ops = module.TTY!.stream_ops
  const oldPoll = ops.poll.bind(ops)

  const pty = module.pty

  ops.poll = (stream, timeout) => {

    if (pty && typeof pty === 'object' && 'readable' in pty && !(pty as { readable: boolean }).readable) {

      const p = pty as { readable: boolean; writable: boolean }
      return (p.readable ? 1 : 0) | (p.writable ? 4 : 0)

    }

    return oldPoll(stream, timeout)

  }

}

/*Tear down QEMU Wasm workers when the terminal unmounts. */
export function stopQemu(module: QemuModule | null) {

  if (!module) return

  try {

    module.PThread?.terminateAllThreads()

  } catch {

    // already stopped

  }

  if (window.Module === module) delete window.Module

}

/** Load QEMU Wasm, preload kernel + disk, and start the VM. */
export async function startQemu(pty: unknown, onProgress: (msg: string) => void): Promise<QemuModule> {

  onProgress('Loading assets...')

  const [kernel, disk] = await Promise.all([

    fetchAsset('/assets/kernel', 'kernel'),
    fetchAsset('/assets/disk.img', 'disk image'),

  ])

  onProgress('Downloading QEMU emulator...')

  const module: QemuModule = {

    arguments: [...QEMU_ARGS],
    pty,

    mainScriptUrlOrBlob: `${location.origin}/qemu/out.js`,

    locateFile: (path) => `/qemu/${path}`,

  }

  preloadAssets(module, kernel, disk)
  window.Module = module

  onProgress('Starting GraniteOS...')

  const url = `${location.origin}/qemu/out.js`

  const { default: init } = await import(/* @vite-ignore */ url) as {

    default: (m: QemuModule) => Promise<void>

  }

  await init(module)
  patchTtyPoll(module)

  return module

}
