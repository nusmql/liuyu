import Foundation

public enum WAVEncoder {
    public static func encodePCM16Mono(frames: [VoiceAudioFrame]) -> Data {
        var pcmData = Data()
        for frame in frames {
            pcmData.append(frame.pcm16MonoData)
        }

        let format = frames.first?.format ?? .pcm16Mono16k
        let sampleRate = UInt32(format.sampleRate)
        let channels = UInt16(format.channels)
        let bitsPerSample = UInt16(format.bitDepth)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(pcmData)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii)!)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
