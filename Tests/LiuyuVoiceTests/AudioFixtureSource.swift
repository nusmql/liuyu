import Foundation
@testable import LiuyuVoice

struct AudioFixtureSource: AudioSource {
    private let scriptedFrames: [VoiceAudioFrame]

    init(wavData: Data, samplesPerFrame: Int) throws {
        guard samplesPerFrame > 0 else {
            throw AudioFixtureSourceError.invalidSamplesPerFrame
        }

        let parsed = try PCM16MonoWAV.parse(wavData)
        let bytesPerFrame = samplesPerFrame * 2
        var frames: [VoiceAudioFrame] = []
        var byteOffset = 0
        var sequence: Int64 = 0
        var samplesEmitted: Int64 = 0

        while byteOffset < parsed.pcmData.count {
            let end = min(byteOffset + bytesPerFrame, parsed.pcmData.count)
            let chunk = parsed.pcmData.subdata(in: byteOffset..<end)
            let timestampNanos = samplesEmitted * 1_000_000_000 / Int64(parsed.sampleRate)
            frames.append(
                VoiceAudioFrame(
                    sequence: sequence,
                    timestampNanos: timestampNanos,
                    format: .pcm16Mono16k,
                    pcm16MonoData: chunk,
                    isPreRoll: false
                )
            )
            sequence += 1
            samplesEmitted += Int64(chunk.count / 2)
            byteOffset = end
        }

        scriptedFrames = frames
    }

    func start() async throws {}

    func stop() async {}

    func frames() -> AsyncStream<VoiceAudioFrame> {
        let frames = scriptedFrames
        return AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

enum AudioFixtureSourceError: Error, Equatable {
    case invalidSamplesPerFrame
    case invalidWAV
    case missingFormatChunk
    case missingDataChunk
    case unsupportedFormat
}

private struct PCM16MonoWAV {
    let sampleRate: Int
    let pcmData: Data

    static func parse(_ data: Data) throws -> PCM16MonoWAV {
        guard data.count >= 12,
              data.asciiString(in: 0..<4) == "RIFF",
              data.asciiString(in: 8..<12) == "WAVE"
        else {
            throw AudioFixtureSourceError.invalidWAV
        }

        var offset = 12
        var format: WAVFormat?
        var pcmData: Data?

        while offset + 8 <= data.count {
            guard let chunkID = data.asciiString(in: offset..<(offset + 4)),
                  let chunkSize = data.uint32LittleEndian(at: offset + 4)
            else {
                throw AudioFixtureSourceError.invalidWAV
            }

            let dataStart = offset + 8
            let dataEnd = dataStart + Int(chunkSize)
            guard dataEnd <= data.count else {
                throw AudioFixtureSourceError.invalidWAV
            }

            if chunkID == "fmt " {
                format = try WAVFormat(data: data, range: dataStart..<dataEnd)
            } else if chunkID == "data" {
                pcmData = data.subdata(in: dataStart..<dataEnd)
            }

            offset = dataEnd + (Int(chunkSize) % 2)
        }

        guard let format else {
            throw AudioFixtureSourceError.missingFormatChunk
        }
        guard let pcmData else {
            throw AudioFixtureSourceError.missingDataChunk
        }
        guard format.audioFormat == 1,
              format.channels == 1,
              format.sampleRate == 16_000,
              format.bitsPerSample == 16,
              pcmData.count % 2 == 0
        else {
            throw AudioFixtureSourceError.unsupportedFormat
        }

        return PCM16MonoWAV(sampleRate: Int(format.sampleRate), pcmData: pcmData)
    }
}

private struct WAVFormat {
    let audioFormat: UInt16
    let channels: UInt16
    let sampleRate: UInt32
    let bitsPerSample: UInt16

    init(data: Data, range: Range<Int>) throws {
        guard range.count >= 16,
              let audioFormat = data.uint16LittleEndian(at: range.lowerBound),
              let channels = data.uint16LittleEndian(at: range.lowerBound + 2),
              let sampleRate = data.uint32LittleEndian(at: range.lowerBound + 4),
              let bitsPerSample = data.uint16LittleEndian(at: range.lowerBound + 14)
        else {
            throw AudioFixtureSourceError.invalidWAV
        }

        self.audioFormat = audioFormat
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
    }
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return String(data: subdata(in: range), encoding: .ascii)
    }

    func uint16LittleEndian(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let value = UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
        return value
    }

    func uint32LittleEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let value = UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
        return value
    }
}
