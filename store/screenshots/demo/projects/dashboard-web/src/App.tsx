import { useState } from "react";

import { RetryLater, upload } from "./api.js";

interface QueueItem {
  name: string;
  state: "queued" | "sending" | "done" | "failed";
}

export function App() {
  const [queue, setQueue] = useState<QueueItem[]>([]);

  async function send(items: File[]) {
    setQueue(items.map((file) => ({ name: file.name, state: "queued" })));
    for (const file of items) {
      try {
        await upload(file);
      } catch (error) {
        if (error instanceof RetryLater) await new Promise((done) => setTimeout(done, error.delayMs));
      }
    }
  }

  return (
    <main>
      <h1>Upload queue</h1>
      <ul>
        {queue.map((item) => (
          <li key={item.name}>{`${item.name}: ${item.state}`}</li>
        ))}
      </ul>
      <input type="file" multiple onChange={(event) => void send([...(event.target.files ?? [])])} />
    </main>
  );
}
