import Foundation

/// Pure expected-total byte selection used for ETA and static-range progress display.
public enum DownloadExpectedBytesPolicy {
    public static func staticRangeExpectedBytes(for record: DownloadRecord) -> Int? {
        guard record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
              let sourcePartSize = record.metadata?.sourcePartSize,
              sourcePartSize > 0 else { return nil }
        return sourcePartSize
    }

    public static func expectedDownloadBytes(record: DownloadRecord,
                                             liveExpectedBytes: Int?,
                                             liveBytes: Int?,
                                             staticExpectedBytes: Int?,
                                             estimatedTranscodeBytes: Int?) -> Int? {
        if let liveExpectedBytes, liveExpectedBytes > 0 {
            return liveExpectedBytes
        }
        let bytes = liveBytes ?? record.bytes
        if record.progress > 0, bytes > 0 {
            return Int(Double(bytes) / record.progress)
        }
        if let staticExpectedBytes {
            return staticExpectedBytes
        }
        return estimatedTranscodeBytes
    }
}
