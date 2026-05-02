import AVFoundation
import XCTest
@testable import LiuyuLib

final class AudioFileBufferWriterTests: XCTestCase {
    func testPreRollEvictionUsesFrameCountInsteadOfBufferCount() {
        let longDeviceBuffers = Array(repeating: 1_600, count: 48)
        XCTAssertEqual(
            preRollEvictionCount(currentFrameLengths: longDeviceBuffers, maxFrames: 16_000),
            38
        )

        let shortDeviceBuffers = Array(repeating: 320, count: 48)
        XCTAssertEqual(
            preRollEvictionCount(currentFrameLengths: shortDeviceBuffers, maxFrames: 16_000),
            0
        )
    }

    func testStreamingChunkSplitKeepsRemainderForLiveStreaming() {
        let data = Data((0..<25).map(UInt8.init))
        let split = streamingChunkSplit(data, chunkSize: 10, includeRemainder: false)

        XCTAssertEqual(split.chunks.map(\.count), [10, 10])
        XCTAssertEqual(split.chunks[0], Data((0..<10).map(UInt8.init)))
        XCTAssertEqual(split.chunks[1], Data((10..<20).map(UInt8.init)))
        XCTAssertEqual(split.remainder, Data((20..<25).map(UInt8.init)))
    }

    func testStreamingChunkSplitCanFlushRemainderAtStop() {
        let data = Data((0..<25).map(UInt8.init))
        let split = streamingChunkSplit(data, chunkSize: 10, includeRemainder: true)

        XCTAssertEqual(split.chunks.map(\.count), [10, 10, 5])
        XCTAssertTrue(split.remainder.isEmpty)
    }

    func testCloseDrainsQueuedWritesBeforeReturning() throws {
        let url = temporaryWAVURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try pcm16MonoFormat()
        let writer = try AudioFileBufferWriter(url: url, format: format)

        for value in 1...6 {
            writer.write(try makeBuffer(format: format, frameLength: 320, sampleValue: Int16(value)))
        }
        writer.close()

        let readFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(readFile.length, 1_920)
    }

    func testWriteCopiesBufferBeforeReturning() throws {
        let url = temporaryWAVURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try pcm16MonoFormat()
        let writer = try AudioFileBufferWriter(url: url, format: format)
        let buffer = try makeBuffer(format: format, frameLength: 320, sampleValue: 1_234)

        writer.write(buffer)
        fill(buffer, sampleValue: 0)
        writer.close()

        let samples = try readSamples(from: url)
        XCTAssertEqual(samples.first, 1_234)
    }

    func testWriteUsesFrameLengthNotFrameCapacity() throws {
        let url = temporaryWAVURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try pcm16MonoFormat()
        let writer = try AudioFileBufferWriter(url: url, format: format)
        let buffer = try makeBuffer(format: format, frameCapacity: 640, frameLength: 320, sampleValue: 7)

        writer.write(buffer)
        writer.close()

        let readFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(readFile.length, 320)
        XCTAssertEqual(try readSamples(from: url).count, 320)
    }

    func testWriteAfterCloseIsIgnored() throws {
        let url = temporaryWAVURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try pcm16MonoFormat()
        let writer = try AudioFileBufferWriter(url: url, format: format)

        writer.close()
        writer.write(try makeBuffer(format: format, frameLength: 320, sampleValue: 9))
        writer.close()

        let readFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(readFile.length, 0)
    }

    private func temporaryWAVURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("liuyu-writer-test-\(UUID().uuidString).wav")
    }

    private func pcm16MonoFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    }

    private func makeBuffer(format: AVAudioFormat, frameLength: AVAudioFrameCount, sampleValue: Int16) throws -> AVAudioPCMBuffer {
        try makeBuffer(format: format, frameCapacity: frameLength, frameLength: frameLength, sampleValue: sampleValue)
    }

    private func makeBuffer(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        frameLength: AVAudioFrameCount,
        sampleValue: Int16
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity))
        buffer.frameLength = frameLength
        fill(buffer, sampleValue: sampleValue)
        return buffer
    }

    private func fill(_ buffer: AVAudioPCMBuffer, sampleValue: Int16) {
        guard let samples = buffer.int16ChannelData?[0] else {
            XCTFail("Expected int16 channel data")
            return
        }
        samples.initialize(repeating: sampleValue, count: Int(buffer.frameLength))
    }

    private func readSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 44)
        let pcmData = data.dropFirst(44)
        return stride(from: 0, to: pcmData.count, by: 2).map { offset in
            let low = UInt16(pcmData[pcmData.index(pcmData.startIndex, offsetBy: offset)])
            let high = UInt16(pcmData[pcmData.index(pcmData.startIndex, offsetBy: offset + 1)]) << 8
            return Int16(bitPattern: low | high)
        }
    }
}
