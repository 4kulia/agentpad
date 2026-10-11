import Foundation

extension TelegramFeedSession {
    struct SendWork: Equatable {
        let operation: UUID
        let index: Int
        var retryID: Int64? = nil
    }

    // One FIFO for the account, including retries. A batch contributes only its
    // next part after success, so files remain sequential without chat queues.
    // The FIFO is deliberately not rebuilt from the journal after a restart:
    // queued parts remain known unsent and can be restored by the user.
    func enqueueSend(_ work: SendWork, validated: Bool = false) {
        guard !sendQueue.contains(work), preparingSend != work else { return }
        sendQueue.append(work)
        drainSendQueue(validated: validated ? work : nil)
    }

    func drainSendQueue(validated: SendWork? = nil) {
        guard !stopped, preparingSend == nil, sending.count < TelegramFeedLimits.concurrentSends,
              network == .ready, now >= retryAt, interactiveCount + externalInteractive() < 6 else { return }
        while let work = sendQueue.first {
            guard let operation = journal.operation(work.operation), journal.recovered(work.operation) != nil,
                  operation.parts[work.index].state == (work.retryID == nil ? .queued : .failed),
                  let feed = feeds[destination(chat: operation.chat, topic: operation.topic)] else { sendQueue.removeFirst(); continue }
            guard !feed.validating else { return }
            sendQueue.removeFirst()
            preparingSend = work
            if work.retryID != nil { prepareRetry(work, feed: feed); return }
            if validated == work { submit(work, feed: feed); return }
            refresh(feed) { [weak self, weak feed] valid in
                guard let self, let feed else { return }
                guard valid, let draft = self.journal.recovered(work.operation), self.validate(draft, feed: feed) else {
                    self.finishPreparing(work, retryLater: self.sendBackpressured); return
                }
                self.validateReply(draft.replyTo, feed: feed) { [weak self, weak feed] valid in
                    guard let self, let feed else { return }
                    if valid { self.submit(work, feed: feed) }
                    else { self.finishPreparing(work, retryLater: self.sendBackpressured) }
                }
            }
            return
        }
    }

    var sendBackpressured: Bool { network != .ready || now < retryAt || interactiveCount + externalInteractive() >= 6 }

    func finishPreparing(_ work: SendWork, retryLater: Bool = false) {
        guard preparingSend == work else { return }
        preparingSend = nil
        if retryLater {
            sendQueue.insert(work, at: 0)
        } else {
            if let retryID = work.retryID, let operation = journal.operation(work.operation),
               operation.parts[work.index].state == .failed { retrying.remove("\(operation.chat):\(retryID)") }
            drainSendQueue()
        }
    }

    func finishSend(_ operation: TelegramSendJournal.Operation, index: Int, succeeded: Bool) {
        let wasSending = sending.remove(operation.parts[index].key) != nil
        // Late outcomes from a previous launch settle the journal, never resume
        // a recovered batch. Only a send started in this session advances it.
        if wasSending, succeeded, operation.parts.indices.contains(index + 1),
           operation.parts[index + 1].state == .queued {
            sendQueue.append(SendWork(operation: operation.id, index: index + 1))
        }
    }
}
