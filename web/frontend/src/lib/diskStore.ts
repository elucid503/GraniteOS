const DB_NAME = 'graniteos'
const STORE = 'assets'
const DISK_KEY = 'disk.img'

function openDb(): Promise<IDBDatabase> {

  return new Promise((resolve, reject) => {

    const req = indexedDB.open(DB_NAME, 1)

    req.onupgradeneeded = () => req.result.createObjectStore(STORE)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)

  })

}

export async function loadDisk(): Promise<Uint8Array | null> {

  const db = await openDb()

  return new Promise((resolve, reject) => {

    const tx = db.transaction(STORE, 'readonly')
    const req = tx.objectStore(STORE).get(DISK_KEY)

    req.onsuccess = () => resolve((req.result as Uint8Array | undefined) ?? null)
    req.onerror = () => reject(req.error)

  })

}

export async function saveDisk(data: Uint8Array): Promise<void> {

  const db = await openDb()

  return new Promise((resolve, reject) => {

    const tx = db.transaction(STORE, 'readwrite')
    const req = tx.objectStore(STORE).put(data, DISK_KEY)

    req.onsuccess = () => resolve()
    req.onerror = () => reject(req.error)

  })

}
