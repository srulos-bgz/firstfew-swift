import Foundation

/// Durable event queue. Events are persisted to disk first
/// (Application Support/FirstFew/queue.json); a 200 response is the ONLY dequeue
/// signal. 429/5xx/network failures retry with backoff (5→10→15→20s, then every
/// 20s); 400/401/402/413 are unrecoverable client errors and drop the batch to
/// avoid a retry loop. The queue is capped at 10k events (oldest dropped first).
final class EventQueue {
    private let token: String
    private let endpoint: URL
    private let queueURL: URL
    private let work = DispatchQueue(label: "com.firstfew.sdk.queue")
    private let session: URLSession
    private var pending: [[String: Any]] = []
    private var flushing = false
    private var retryDelay: TimeInterval = 5
    private let maxPending = 10_000
    private let batchSize = 100 // well below the server's 500-event / 1 MB limits

    init(token: String, baseURL: URL) {
        self.token = token
        self.endpoint = baseURL.appendingPathComponent("api/ingest/events")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FirstFew", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.queueURL = dir.appendingPathComponent("queue.json")
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        work.async { self.load() }
    }

    func add(_ event: [String: Any]) {
        work.async {
            if self.pending.count >= self.maxPending {
                self.pending.removeFirst()
            }
            self.pending.append(event)
            self.save()
            self.flush()
        }
    }

    // MARK: - Everything below runs on the work queue

    private func load() {
        if let data = try? Data(contentsOf: queueURL),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            pending = arr + pending // events left over from the previous run go first
        }
        flush()
    }

    private func save() {
        guard JSONSerialization.isValidJSONObject(pending),
              let data = try? JSONSerialization.data(withJSONObject: pending) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func flush() {
        guard !flushing, !pending.isEmpty else { return }
        flushing = true
        let batch = Array(pending.prefix(batchSize))
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["events": batch])
        session.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self else { return }
            self.work.async { self.handle(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, sent: batch.count) }
        }.resume()
    }

    private func handle(status: Int, sent: Int) {
        flushing = false
        switch status {
        case 200:
            // Persisted server-side (duplicates and rejected rows are also final) — dequeue.
            pending.removeFirst(min(sent, pending.count))
            save()
            retryDelay = 5
            flush()
        case 400, 401, 402, 413:
            // Unrecoverable client error: drop the batch to avoid a retry loop
            // (402 = monthly quota reached, the server is dropping events too).
            pending.removeFirst(min(sent, pending.count))
            save()
            flush()
        default:
            // Network failure / 429 / 5xx: keep the events, back off, retry.
            let delay = retryDelay
            retryDelay = min(retryDelay + 5, 20)
            work.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
        }
    }
}
